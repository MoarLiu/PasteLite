import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var historyStore: SQLiteHistoryStore

    let onCopy: (ClipboardItem) -> Void
    let onPaste: (ClipboardItem) -> Void
    let onRemove: (ClipboardItem) -> Void
    let onClear: () -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    private var filteredItems: [ClipboardItem] {
        appState.filteredItems(in: historyStore.items)
    }

    private var sections: [HistoryDateSection] {
        HistoryDateSection.sections(for: filteredItems)
    }

    private var selectedItem: ClipboardItem? {
        appState.selectedItem(in: filteredItems)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let message = historyStore.errorMessage ?? historyStore.storageWarning {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 0) {
                list
                Divider()
                DetailView(item: selectedItem, historyStore: historyStore)
            }
            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 420)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        )
        .onAppear {
            searchFocused = true
            appState.normalizeSelection(in: filteredItems)
        }
        .onChange(of: historyStore.items) { _ in
            appState.normalizeSelection(in: filteredItems)
        }
        .onChange(of: appState.searchText) { _ in
            appState.normalizeSelection(in: filteredItems)
        }
        .onChange(of: appState.selectedFilter) { _ in
            appState.normalizeSelection(in: filteredItems)
        }
        .onChange(of: appState.presentationVersion) { _ in
            searchFocused = true
            appState.normalizeSelection(in: filteredItems)
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            TextField("Type to filter entries...", text: $appState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($searchFocused)

            Picker("", selection: $appState.selectedFilter) {
                ForEach(HistoryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .controlSize(.regular)
            .frame(width: 156)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var panelBackground: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Rectangle()
                .fill(Color.white.opacity(0.34))
        }
    }

    private var list: some View {
        let displayedSections = sections
        let selectedID = selectedItem?.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(filteredItems.isEmpty ? "History" : displayedSections.first?.title ?? "History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if historyStore.isLoading {
                ProgressView("Loading history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(displayedSections) { section in
                            Section {
                                ForEach(section.items) { item in
                                    row(for: item, selectedID: selectedID)
                                }
                            } header: {
                                if section.id != displayedSections.first?.id {
                                    Text(section.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.top, 8)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 300)
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .medium))
            Text("No Items")
                .font(.system(size: 13, weight: .semibold))
            Text(appState.searchText.isEmpty ? "Clipboard history is empty." : "No history items match this filter.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func row(for item: ClipboardItem, selectedID: ClipboardItem.ID?) -> some View {
        HistoryRowView(
            item: item,
            isSelected: selectedID == item.id,
            historyStore: historyStore
        )
        .contentShape(Rectangle())
        .onTapGesture {
            searchFocused = false
            appState.selectedItemID = item.id
        }
        .onTapGesture(count: 2) {
            onPaste(item)
        }
        .contextMenu {
            Button {
                onCopy(item)
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.doc")
            }

            Button {
                onPaste(item)
            } label: {
                Label("Paste", systemImage: "arrow.down.doc")
            }

            Divider()

            Button(role: .destructive) {
                onRemove(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if appState.isPerformingClipboardAction {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing clipboard item…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let statusMessage = appState.statusMessage {
                Label(statusMessage, systemImage: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.9))
                        Image(systemName: "clipboard")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 22, height: 22)

                    Text("Clipboard History")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            footerActionButton(
                title: pasteTitle,
                systemImage: "arrow.down.doc",
                isDisabled: selectedItem == nil || appState.isPerformingClipboardAction
            ) {
                if let selectedItem {
                    onPaste(selectedItem)
                }
            }

            Divider()
                .frame(height: 22)

            footerActionButton(
                title: "Copy",
                systemImage: "doc.on.doc",
                shortcut: "↵",
                isDisabled: selectedItem == nil || appState.isPerformingClipboardAction
            ) {
                if let selectedItem {
                    onCopy(selectedItem)
                }
            }

            footerActionButton(
                title: "Delete",
                systemImage: "trash",
                isDestructive: true,
                isDisabled: selectedItem == nil || appState.isPerformingClipboardAction
            ) {
                if let selectedItem {
                    onRemove(selectedItem)
                }
            }

            footerActionButton(
                title: "Clear All",
                systemImage: "trash.slash",
                isDestructive: true,
                isDisabled: historyStore.items.isEmpty || appState.isPerformingClipboardAction
            ) {
                onClear()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.28))
    }

    private var pasteTitle: String {
        if let appName = appState.pasteTargetName, !appName.isEmpty {
            return "Paste to \(appName)"
        }
        return "Paste"
    }

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 20, minHeight: 18)
            .padding(.horizontal, 2)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func footerActionButton(
        title: String,
        systemImage: String,
        shortcut: String? = nil,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let shortcut {
                    keyCap(shortcut)
                }
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .opacity(isDisabled ? 0.45 : 1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct HistoryDateSection: Identifiable {
    let day: Date
    let title: String
    var items: [ClipboardItem]

    var id: TimeInterval { day.timeIntervalSinceReferenceDate }

    static func sections(
        for items: [ClipboardItem],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [HistoryDateSection] {
        let sortedItems = items.sorted { $0.copiedAt > $1.copiedAt }
        var sections: [HistoryDateSection] = []

        for item in sortedItems {
            let day = calendar.startOfDay(for: item.copiedAt)
            if let index = sections.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
                sections[index].items.append(item)
            } else {
                sections.append(
                    HistoryDateSection(
                        day: day,
                        title: title(for: day, calendar: calendar),
                        items: [item]
                    )
                )
            }
        }

        return sections
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "Today"
        }

        if calendar.isDateInYesterday(day) {
            return "Yesterday"
        }

        return DateFormatter.localizedString(from: day, dateStyle: .medium, timeStyle: .none)
    }
}
