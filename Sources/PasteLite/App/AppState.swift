import Foundation

enum PanelMode: String, CaseIterable, Identifiable, Sendable {
    case history, library
    var id: String { rawValue }
    var title: String { self == .history ? "History" : "Saved" }
}

private struct PanelListMemory {
    var query = ""
    var filter: HistoryFilter = .all
    var selection: UUID?
    var index: Int?
}

@MainActor
final class AppState: ObservableObject {
    @Published var searchText = "" { didSet { if oldValue != searchText { criteriaChanged() } } }
    @Published var selectedFilter: HistoryFilter = .all { didSet { if oldValue != selectedFilter { criteriaChanged() } } }
    @Published var mode: PanelMode = .history {
        didSet {
            guard mode != oldValue, !isSwitchingMode else { return }
            listMemory[oldValue] = PanelListMemory(query: searchText, filter: selectedFilter, selection: selectedItemID, index: lastResolvedSelectionIndex)
            let restored = listMemory[mode] ?? PanelListMemory()
            isSwitchingMode = true
            searchText = restored.query
            selectedFilter = restored.filter
            selectedItemID = restored.selection
            lastResolvedSelectionIndex = restored.index
            isSwitchingMode = false
            requestResults()
        }
    }
    @Published var selectedGroup: LibraryGroupSelection = .all {
        didSet {
            guard selectedGroup != oldValue else { return }
            AppPreferences.shared.lastLibraryGroup = selectedGroup.storedValue
            criteriaChanged()
        }
    }
    @Published var selectedItemID: UUID?
    @Published var statusMessage: String?
    @Published var pasteTargetName: String?
    @Published var isPerformingClipboardAction = false
    @Published var actionsPresented = false
    @Published private(set) var presentationVersion = 0
    @Published private(set) var keyboardSelectionVersion = 0
    @Published private(set) var visibleItems: [ClipboardItem] = []
    @Published private(set) var filterCounts: [HistoryFilter: Int] = [:]
    @Published private(set) var isUpdatingResults = false
    @Published var editorDraft: LibraryDraft?
    @Published var groupDraft: LibraryGroupDraft?
    @Published var editorCloseRequest = 0
    @Published var isEditorSaving = false
    private var initialEditorDraft: LibraryDraft?
    private var afterEditorDismissal: (@MainActor () -> Void)?
    private var listMemory: [PanelMode: PanelListMemory] = [:]
    private var sourceHistory: [ClipboardItem] = []
    private var sourceLibrary: [LibraryItem] = []
    private var resultTask: Task<Void, Never>?
    private var resultRequest = 0
    private var isSwitchingMode = false
    private var resetSelectionOnResults = false
    private var statusClearTask: Task<Void, Never>?

    init() {
        selectedGroup = LibraryGroupSelection(storedValue: AppPreferences.shared.lastLibraryGroup)
    }

    func prepareForPresentation() {
        isSwitchingMode = true
        let historyFilter = mode == .history ? selectedFilter : listMemory[.history]?.filter ?? .all
        listMemory = [:]
        mode = .history
        searchText = ""
        selectedFilter = historyFilter == .pinned ? .all : historyFilter
        actionsPresented = false
        selectedItemID = nil
        lastResolvedSelectionIndex = nil
        clearStatus()
        presentationVersion += 1
        isSwitchingMode = false
        resetSelectionOnResults = true
        requestResults()
    }

    func refreshResults(history: [ClipboardItem], library: [LibraryItem], groups: [LibraryGroup]) {
        sourceHistory = history
        sourceLibrary = library
        if let id = selectedGroup.groupID, !groups.contains(where: { $0.id == id }) { selectedGroup = .all }
        requestResults()
    }

    func revealSaved(_ item: LibraryItem) {
        if mode == .history {
            listMemory[.history] = PanelListMemory(query: searchText, filter: selectedFilter, selection: selectedItemID, index: lastResolvedSelectionIndex)
        }
        isSwitchingMode = true
        mode = .library
        selectedGroup = item.groupID.map(LibraryGroupSelection.group) ?? .ungrouped
        selectedFilter = .all
        searchText = ""
        selectedItemID = item.id
        isSwitchingMode = false
        resetSelectionOnResults = false
        requestResults()
    }

    func switchMode() { mode = mode == .history ? .library : .history }

    var hasUnsavedEditorChanges: Bool { editorDraft != nil && editorDraft != initialEditorDraft }

    func beginEditing(_ draft: LibraryDraft) {
        guard editorDraft == nil, groupDraft == nil else { return }
        initialEditorDraft = draft
        editorDraft = draft
    }

    func requestEditorDismissal(afterDismiss: (@MainActor () -> Void)? = nil) {
        guard editorDraft != nil else { afterDismiss?(); return }
        afterEditorDismissal = afterDismiss
        editorCloseRequest += 1
    }

    func finishEditing() {
        editorDraft = nil
        initialEditorDraft = nil
        isEditorSaving = false
        let completion = afterEditorDismissal
        afterEditorDismissal = nil
        completion?()
    }

    func continueEditing() { afterEditorDismissal = nil }

    private func criteriaChanged() {
        guard !isSwitchingMode else { return }
        resetSelectionOnResults = true
        requestResults()
    }

    private func requestResults() {
        guard !isSwitchingMode else { return }
        resultTask?.cancel()
        resultRequest += 1
        let request = resultRequest
        let input = PanelQuery(mode: mode, query: searchText, filter: selectedFilter, group: selectedGroup,
                               history: sourceHistory, library: sourceLibrary)
        isUpdatingResults = true
        resultTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { input.results() }
            let output = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, request == self.resultRequest else { return }
            self.visibleItems = output.items
            self.filterCounts = output.counts
            self.normalizeSelection(in: output.items, resetIndex: self.resetSelectionOnResults)
            self.resetSelectionOnResults = false
            self.isUpdatingResults = false
            self.resultTask = nil
        }
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
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.copiedAt > $1.copiedAt
        }
    }

    func selectedItem(in items: [ClipboardItem]) -> ClipboardItem? {
        if let selectedItemID,
           let index = items.firstIndex(where: { $0.id == selectedItemID }) {
            lastResolvedSelectionIndex = index
            return items[index]
        }
        return items.first
    }

    private var lastResolvedSelectionIndex: Int?

    func normalizeSelection(in items: [ClipboardItem], resetIndex: Bool = false) {
        guard !items.isEmpty else {
            selectedItemID = nil
            lastResolvedSelectionIndex = nil
            return
        }

        if !resetIndex, let selectedItemID,
           let index = items.firstIndex(where: { $0.id == selectedItemID }) {
            lastResolvedSelectionIndex = index
            return
        }

        let fallbackIndex = resetIndex ? 0 : min(lastResolvedSelectionIndex ?? 0, items.count - 1)
        selectedItemID = items[fallbackIndex].id
        lastResolvedSelectionIndex = fallbackIndex
    }

    func moveSelection(delta: Int, in items: [ClipboardItem]) {
        guard !items.isEmpty else {
            selectedItemID = nil
            lastResolvedSelectionIndex = nil
            return
        }

        let currentIndex = selectedItemID.flatMap { id in
            items.firstIndex(where: { $0.id == id })
        } ?? 0
        let targetIndex = min(max(currentIndex + delta, 0), items.count - 1)
        selectedItemID = items[targetIndex].id
        lastResolvedSelectionIndex = targetIndex
        keyboardSelectionVersion += 1
    }
}

struct PanelQuery: Sendable {
    let mode: PanelMode
    let query: String
    let filter: HistoryFilter
    let group: LibraryGroupSelection
    let history: [ClipboardItem]
    let library: [LibraryItem]

    struct Results: Sendable {
        var items: [ClipboardItem]
        var counts: [HistoryFilter: Int]
    }

    func results() -> Results {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [ClipboardItem]
        if mode == .history { candidates = history }
        else {
            candidates = library.filter {
                switch group {
                case .all: return true
                case .ungrouped: return $0.groupID == nil
                case let .group(id): return $0.groupID == id
                }
            }.map(\.displayItem)
        }
        var counts: [HistoryFilter: Int] = [:]
        var matches: [(ClipboardItem, Int)] = []
        for item in candidates {
            if Task.isCancelled { return .init(items: [], counts: [:]) }
            for type in HistoryFilter.contentFilters where type.matches(item) { counts[type, default: 0] += 1 }
            guard filter.matches(item) else { continue }
            let rank = searchRank(text, item: item)
            guard rank != nil else { continue }
            matches.append((item, rank ?? 4))
        }
        matches.sort {
            if mode == .history {
                if $0.0.isPinned != $1.0.isPinned { return $0.0.isPinned }
                if $0.0.copiedAt != $1.0.copiedAt { return $0.0.copiedAt > $1.0.copiedAt }
            } else {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                let order = $0.0.title.localizedStandardCompare($1.0.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }
        return .init(items: matches.map(\.0), counts: counts)
    }

    private func searchRank(_ query: String, item: ClipboardItem) -> Int? {
        guard !query.isEmpty else { return 4 }
        if item.kind == .concealed {
            return item.title.localizedCaseInsensitiveContains(query) || (item.sourceAppName?.localizedCaseInsensitiveContains(query) ?? false) ? 4 : nil
        }
        if item.title.compare(query, options: .caseInsensitive) == .orderedSame { return 0 }
        if item.title.lowercased().hasPrefix(query.lowercased()) { return 1 }
        if item.title.localizedCaseInsensitiveContains(query) { return 2 }
        if item.previewText.localizedCaseInsensitiveContains(query) || (item.sourceAppName?.localizedCaseInsensitiveContains(query) ?? false) { return 3 }
        return nil
    }
}

extension HistoryFilter {
    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            return true
        case .pinned:
            return item.isPinned
        case .text:
            return [.text, .code, .concealed].contains(item.kind)
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
