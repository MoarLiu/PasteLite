import AppKit
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct LibraryBehaviorTests {
    @Test func searchRanksNamesBeforeContentAndCombinesGroupAndType() {
        let group = UUID()
        let entries = [entry("deploy", text: "A", group: group), entry("deploy test", text: "B", group: group),
                       entry("my deploy", text: "C", group: group), entry("other", text: "deploy", group: group),
                       entry("deploy elsewhere", text: "D", group: nil)]
        let result = PanelQuery(mode: .library, query: "DEPLOY", filter: .text, group: .group(group), history: [], library: entries).results()
        #expect(result.items.map(\.title) == ["deploy", "deploy test", "my deploy", "other"])
        #expect(result.counts[.all] == 4)
        #expect(PanelQuery(mode: .library, query: "deploy", filter: .image, group: .all, history: [], library: entries).results().items.isEmpty)
    }

    @Test func chineseBodyAndSourceAreSearchable() {
        let entries = [entry("需求整理", text: "请整理开发需求"), entry("Command", text: "ssh host")]
        #expect(PanelQuery(mode: .library, query: "开发", filter: .all, group: .all, history: [], library: entries).results().items.map(\.title) == ["需求整理"])
        #expect(PanelQuery(mode: .library, query: "Notes", filter: .all, group: .all, history: [], library: entries).results().items.count == 2)
    }

    @Test func modesRememberQueriesAndSelectionWithinOnePresentation() async throws {
        let state = AppState()
        let history = [librarySample("History one"), librarySample("History two")]
        let saved = [entry("Saved", text: "text")]
        state.refreshResults(history: history, library: saved, groups: [])
        try await resultsReady(state)
        state.searchText = "one"
        try await resultsReady(state)
        let selected = state.selectedItemID
        state.mode = .library
        try await resultsReady(state)
        state.searchText = "Saved"
        try await resultsReady(state)
        state.mode = .history
        try await resultsReady(state)
        #expect(state.searchText == "one")
        #expect(state.selectedItemID == selected)
        state.prepareForPresentation()
        try await resultsReady(state)
        #expect(state.mode == .history && state.searchText.isEmpty)
        state.mode = .library
        try await resultsReady(state)
        #expect(state.searchText.isEmpty)
    }

    @Test func renameKeepsSelectionAndDeletionSelectsNeighbor() async throws {
        let state = AppState()
        var saved = [entry("A", text: "one"), entry("B", text: "two"), entry("C", text: "three")]
        state.mode = .library
        state.refreshResults(history: [], library: saved, groups: [])
        try await resultsReady(state)
        state.moveSelection(delta: 1, in: state.visibleItems)
        let chosen = state.selectedItemID
        saved[1].name = "BB"
        state.refreshResults(history: [], library: saved, groups: [])
        try await resultsReady(state)
        #expect(state.selectedItemID == chosen)
        saved.remove(at: 1)
        state.refreshResults(history: [], library: saved, groups: [])
        try await resultsReady(state)
        #expect(state.selectedItemID == saved.last?.id)
    }

    @Test func copyingSavedContentUsesItsOwnAssetsAfterHistoryIsGone() async throws {
        try await libraryFixture { store, _, _ in
            let board = NSPasteboard(name: .init("PasteLiteLibraryCopy-\(UUID())"))
            defer { board.releaseGlobally() }
            let source = librarySample("Saved clipboard data")
            _ = await store.add(source)
            _ = await store.saveLibrary(snapshotDraft(source, name: "Alias", generation: store.libraryGeneration))
            _ = await store.clear()
            let saved = try #require(store.libraryItems.first)
            let service = PasteService(historyStore: store, pasteboard: board)
            #expect(await service.copyToClipboard(saved.displayItem) == .success)
            #expect(board.string(forType: .string) == "Saved clipboard data")
        }
    }

    @Test func staleSavedSelectionNeverWritesTheClipboard() async throws {
        try await libraryFixture { store, _, _ in
            let board = NSPasteboard(name: .init("PasteLiteLibraryStale-\(UUID())"))
            defer { board.releaseGlobally() }
            board.setString("Untouched", forType: .string)
            var draft = snippetDraft(name: "Snippet", body: "Old", generation: store.libraryGeneration)
            _ = await store.saveLibrary(draft)
            let old = try #require(store.libraryItems.first)
            draft.editingID = old.id; draft.expectedRevision = old.revision; draft.body = "New"
            _ = await store.saveLibrary(draft)
            let service = PasteService(historyStore: store, pasteboard: board)
            #expect(!(await service.copyToClipboard(old.displayItem)).isSuccess)
            #expect(board.string(forType: .string) == "Untouched")
        }
    }

    @Test func editorTracksDraftAndCanContinueAfterQuitRequest() {
        let state = AppState()
        let draft = snippetDraft(name: "Snippet", body: "Text", generation: 0)
        state.beginEditing(draft)
        #expect(!state.hasUnsavedEditorChanges)
        state.editorDraft?.body = "Changed"
        #expect(state.hasUnsavedEditorChanges)
        var didQuit = false
        state.requestEditorDismissal { didQuit = true }
        #expect(state.editorCloseRequest == 1)
        state.continueEditing()
        state.finishEditing()
        #expect(!didQuit)
        #expect(state.editorDraft == nil)
    }

    @Test func queryTimingWithFiveThousandHistoryItems() {
        let history = (0..<5000).map { librarySample("Entry \($0) 中文 English content").metadataOnly }
        let saved = (0..<200).map { entry("Saved \($0)", text: "Snippet text") }
        var timings: [Double] = []
        for index in 0..<30 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = PanelQuery(mode: index.isMultiple(of: 2) ? .history : .library, query: index.isMultiple(of: 2) ? "Entry 1" : "Saved", filter: .all, group: .all, history: history, library: saved).results()
            #expect(result.items.count == (index.isMultiple(of: 2) ? 1111 : 200))
            #expect(result.counts[.all] == (index.isMultiple(of: 2) ? 5000 : 200))
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let p95 = timings.sorted()[28]
        print("PasteLite 0.4.0 query pipeline: 5000 history + 200 saved, 30 samples, p95 \(String(format: "%.2f", p95)) ms")
        // A wall-clock budget is meaningful only on the recorded reference
        // machine/configuration, not an arbitrary shared CI runner.
        if let value = ProcessInfo.processInfo.environment["PASTELITE_QUERY_P95_BUDGET_MS"],
           let budget = Double(value), budget > 0 {
            #expect(p95 <= budget)
        }
    }
}

private func entry(_ name: String, text: String, group: UUID? = nil) -> PasteLite.LibraryItem {
    let item = librarySample(text)
    return PasteLite.LibraryItem(id: item.id, groupID: group, name: name, type: .snippet, content: item,
                       sourceHistoryID: nil, sourceContentHash: nil, savedAt: Date(), updatedAt: Date(), lastUsedAt: nil, revision: 1)
}

@MainActor
func resultsReady(_ state: AppState) async throws {
    for _ in 0..<300 {
        if !state.isUpdatingResults { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("Search results did not finish")
}
