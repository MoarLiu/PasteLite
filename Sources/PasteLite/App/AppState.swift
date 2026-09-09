import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var searchText = ""
    @Published var selectedFilter: HistoryFilter = .all
    @Published var selectedItemID: UUID?
    @Published var statusMessage: String?
    @Published var pasteTargetName: String?
    @Published var isPerformingClipboardAction = false
    @Published private(set) var presentationVersion = 0
    private var statusClearTask: Task<Void, Never>?

    func prepareForPresentation() {
        searchText = ""
        selectedItemID = nil
        clearStatus()
        presentationVersion += 1
    }

    func showStatus(_ message: String, clearAfter seconds: TimeInterval = 3) {
        statusClearTask?.cancel()
        statusMessage = message

        let nanoseconds = UInt64(seconds * 1_000_000_000)
        statusClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.clearStatus()
        }
    }

    func clearStatus() {
        statusClearTask?.cancel()
        statusClearTask = nil
        statusMessage = nil
    }

    func filteredItems(in items: [ClipboardItem]) -> [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return items.filter { item in
            guard selectedFilter.matches(item) else { return false }
            guard !query.isEmpty else { return true }

            return item.title.localizedCaseInsensitiveContains(query) ||
                item.previewText.localizedCaseInsensitiveContains(query) ||
                (item.sourceAppName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func selectedItem(in items: [ClipboardItem]) -> ClipboardItem? {
        if let selectedItemID,
           let selected = items.first(where: { $0.id == selectedItemID }) {
            return selected
        }
        return items.first
    }

    func normalizeSelection(in items: [ClipboardItem]) {
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }

        if let selectedItemID,
           items.contains(where: { $0.id == selectedItemID }) {
            return
        }

        selectedItemID = items.first?.id
    }

    func moveSelection(delta: Int, in items: [ClipboardItem]) {
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }

        let currentIndex = selectedItemID.flatMap { id in
            items.firstIndex(where: { $0.id == id })
        } ?? 0
        let targetIndex = min(max(currentIndex + delta, 0), items.count - 1)
        selectedItemID = items[targetIndex].id
    }
}

private extension HistoryFilter {
    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            return true
        case .text:
            return item.kind == .text
        case .image:
            return item.kind == .image
        case .file:
            return item.kind == .file
        case .link:
            return item.kind == .link
        case .color:
            return item.kind == .color
        }
    }
}
