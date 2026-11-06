import AppKit
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct Completion041Tests {
    @Test func backupRestoresRichFormatsNamesGroupsAndImages() async throws {
        try await libraryFixture { store, _, directory in
            _ = await store.createGroup("提示词")
            let group = try #require(store.libraryGroups.first)
            var source = librarySample("Rich original")
            source.assets.append(.init(index: 0, pasteboardType: .html, data: Data("<b>Rich original</b>".utf8)))
            source.contentHash = ClipboardContentHasher.hash(assets: source.assets)
            var draft = snapshotDraft(source, name: "Named rich text", generation: store.libraryGeneration)
            draft.groupID = group.id
            _ = await store.saveLibrary(draft)
            var image = source
            image.kind = .image; image.title = "Image"
            image.assets = [.init(index: 0, pasteboardType: .png, data: Data([137, 80, 78, 71]))]
            image.contentHash = ClipboardContentHasher.hash(assets: image.assets)
            _ = await store.saveLibrary(snapshotDraft(image, name: "Saved image", generation: store.libraryGeneration))
            _ = await store.saveLibrary(snippetDraft(name: "Code", body: "\n print(1)\n", generation: store.libraryGeneration))
            let url = directory.deletingLastPathComponent().appendingPathComponent("backup.json")
            try await store.exportLibrary(to: url)
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
            _ = await store.clearLibrary()
            let result = try await store.importLibrary(from: url)
            #expect(result.added == 3 && result.skipped == 0)
            let rich = try #require(store.libraryItems.first { $0.name == "Named rich text" })
            #expect(rich.groupID == group.id)
            let loaded = try await store.resolve(rich.displayItem)
            #expect(loaded.assets.contains { $0.pasteboardType == .html && $0.data == Data("<b>Rich original</b>".utf8) })
            #expect(store.libraryItems.first { $0.name == "Code" }?.content.previewText == "\n print(1)\n")
            #expect(try await store.importLibrary(from: url).skipped == 3)
        }
    }

    @Test func importKeepsLocalEditsAndMergesGroupsByName() async throws {
        try await libraryFixture { store, _, directory in
            _ = await store.createGroup("Work")
            var draft = snippetDraft(name: "Original", body: "Original", generation: store.libraryGeneration)
            draft.groupID = store.libraryGroups.first?.id
            _ = await store.saveLibrary(draft)
            let item = try #require(store.libraryItems.first)
            let url = directory.deletingLastPathComponent().appendingPathComponent("backup.json")
            try await store.exportLibrary(to: url)
            draft.editingID = item.id; draft.expectedRevision = item.revision
            draft.name = "Local edit"; draft.body = "Current text"
            _ = await store.saveLibrary(draft)
            #expect(try await store.importLibrary(from: url).skipped == 1)
            #expect(store.libraryItems.first?.name == "Local edit")
            #expect(store.libraryItems.first?.content.previewText == "Current text")
            #expect(store.libraryGroups.count == 1)
            var archive = try LibraryArchive.read(from: url)
            archive.groups[0].name = " work "
            try archive.write(to: url)
            #expect(try await store.importLibrary(from: url).skipped == 1)
            #expect(store.libraryGroups.count == 1)
        }
    }

    @Test func importFailureRollsBackAllItemsAndGroups() async throws {
        try await libraryFixture { store, database, directory in
            _ = await store.createGroup("Backup group")
            _ = await store.saveLibrary(snippetDraft(name: "Incoming", body: "Body", generation: store.libraryGeneration))
            let url = directory.deletingLastPathComponent().appendingPathComponent("backup.json")
            try await store.exportLibrary(to: url)
            _ = await store.clearLibrary()
            try database.execute("CREATE TRIGGER fail_import BEFORE INSERT ON library_assets BEGIN SELECT RAISE(ABORT, 'injected'); END;")
            await #expect(throws: (any Error).self) { _ = try await store.importLibrary(from: url) }
            await store.loadLibrary()
            #expect(store.libraryItems.isEmpty && store.libraryGroups.isEmpty)
            try database.execute("DROP TRIGGER fail_import;")
            #expect(try await store.importLibrary(from: url).added == 1)
        }
    }

    @Test func invalidBackupRejectsSecretsDuplicateFormatsAndMissingGroups() throws {
        var source = librarySample("secret")
        var entry = LibraryArchive.Entry(LibraryItem(id: source.id, name: "Item", type: .snapshot, content: source,
            savedAt: Date(), updatedAt: Date(), revision: 1))
        var archive = LibraryArchive(groups: [], items: [entry])
        entry.kind = "concealed"; archive.items = [entry]
        #expect(throws: LibraryError.self) { _ = try archive.validatedItems() }
        entry.kind = "text"; entry.groupID = UUID(); archive.items = [entry]
        #expect(throws: LibraryError.self) { _ = try archive.validatedItems() }
        entry.groupID = nil; entry.assets.append(entry.assets[0]); archive.items = [entry]
        #expect(throws: LibraryError.self) { _ = try archive.validatedItems() }
        source.assets = [.init(index: 0, pasteboardType: .concealed, data: Data("secret".utf8))]
        #expect(throws: LibraryError.self) { try LibraryValidation.snapshot(source) }
    }

    @Test func ocrPersistsSearchesAndCannotReturnAfterClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite3")
        let repository = HistoryRepository(databaseURL: url, limit: 500)
        var image = librarySample("Image")
        image.kind = .image
        _ = await repository.add(image)
        let snapshot = try await repository.saveRecognizedText("需求检查 PASTELITE", item: image, historyGeneration: 0, savedGeneration: 0)
        #expect(snapshot.items.first?.recognizedText == "需求检查 PASTELITE")
        let reopened = HistoryRepository(databaseURL: url, limit: 500)
        let loaded = await reopened.loadRecentItems(limit: 500)
        #expect(loaded.items.first?.hasRecognizedText == true)
        let result = PanelQuery(mode: .history, query: "需求", filter: .image, group: .all, history: loaded.items, library: []).results()
        #expect(result.items.count == 1)
        _ = await repository.clear(captureGeneration: 1, includePinned: true)
        await #expect(throws: LibraryError.self) { _ = try await repository.saveRecognizedText("late", item: image, historyGeneration: 0, savedGeneration: 0) }
        let database = try SQLiteDatabase(url: url)
        let query = try database.prepare("SELECT COUNT(*) FROM recognized_text;")
        #expect(try query.step())
        #expect(query.columnInt64(at: 0) == 0)
    }

    @Test func visionRecognizesActualImageText() async throws {
        let image = NSImage(size: NSSize(width: 800, height: 200))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 800, height: 200).fill()
        ("PASTELITE 041" as NSString).draw(at: NSPoint(x: 30, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 70), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let text = try await OCRService.shared.recognize(tiff)
        #expect(text.uppercased().contains("PASTELITE"))
    }

    @Test func sourceFilterCombinesWithOCRAndGroup() {
        let group = UUID()
        var first = librarySample("Picture")
        first.sourceAppName = "Editor"; first.sourceBundleIdentifier = "example.editor"
        first.kind = .image; first.recognizedText = "searchable image"
        let entry = LibraryItem(id: first.id, groupID: group, name: "Saved", type: .snapshot, content: first,
            savedAt: Date(), updatedAt: Date(), revision: 1)
        #expect(PanelQuery(mode: .library, query: "searchable", filter: .image, group: .group(group), source: "example.editor", history: [], library: [entry]).results().items.count == 1)
        #expect(PanelQuery(mode: .library, query: "searchable", filter: .image, group: .group(group), source: "other", history: [], library: [entry]).results().items.isEmpty)
    }

    @Test func multiSelectionKeepsChosenOrderAndPrunesHiddenItems() async throws {
        let state = AppState()
        let first = librarySample("First"), second = librarySample("Second")
        state.refreshResults(history: [first, second], library: [], groups: [])
        try await resultsReady(state)
        state.isSelecting = true
        state.toggleSelection(second); state.toggleSelection(first)
        #expect(state.selectedItems.map(\.id) == [second.id, first.id])
        state.searchText = "First"
        try await resultsReady(state)
        #expect(state.multiSelection == [first.id])
        state.addToStack(state.selectedItems)
        #expect(state.stack.first?.id == first.id)
        state.mode = .library
        #expect(state.multiSelection.isEmpty)
    }

    @Test func mergedCopyPreservesOrderWhitespaceAndRejectsUnmergeableItems() throws {
        let first = librarySample(" A\n"), second = librarySample("B")
        let result = try MergedCopy.item(from: [second, first], separator: "\n\n")
        #expect(result.assets.first?.data == Data("B\n\n A\n".utf8))
        var image = first
        image.kind = .image; image.assets = [.init(index: 0, pasteboardType: .png, data: Data([1]))]
        #expect(throws: LibraryError.self) { _ = try MergedCopy.item(from: [first, image], separator: "\n") }
        var secret = first; secret.kind = .concealed
        #expect(throws: LibraryError.self) { _ = try MergedCopy.item(from: [secret], separator: "") }
    }

    @Test func v4DatabaseAddsOCRWithoutBreakingRollbackCompatibility() async throws {
        try await libraryFixture { store, database, directory in
            _ = await store.saveLibrary(snippetDraft(name: "Existing", body: "Keep", generation: store.libraryGeneration))
            let id = try #require(store.libraryItems.first?.id)
            try database.execute("PRAGMA user_version = 4;")
            let reopened = SQLiteHistoryStore(databaseURL: directory)
            await reopened.loadLibrary()
            let item = try #require(reopened.libraryItems.first)
            #expect(item.id == id)
            #expect(try await reopened.resolve(item.displayItem).assets.first?.data == Data("Keep".utf8))
            let version = try database.prepare("PRAGMA user_version;")
            #expect(try version.step()); #expect(version.columnInt64(at: 0) == 4)
            let ocr = try database.prepare("SELECT COUNT(*) FROM recognized_text;")
            #expect(try ocr.step())
        }
    }

    @Test func stackPopsOnlyOnSuccessAndKeepsFailedHead() async throws {
        try await libraryFixture { store, _, _ in
            let target = try #require(NSWorkspace.shared.runningApplications.first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular })
            let first = librarySample("First queued"), second = librarySample("Second queued")
            _ = await store.add(first); _ = await store.add(second)
            let board = NSPasteboard(name: .init("PasteLiteStackTest-\(UUID())"))
            defer { board.releaseGlobally() }
            let environment = StackTestEnvironment(target: target)
            let state = AppState()
            let controller = HistoryPanelController(appState: state, historyStore: store,
                pasteService: PasteService(historyStore: store, pasteboard: board, environment: environment))
            controller.toggle(target: target)
            defer { controller.close() }
            try await resultsReady(state)
            state.addToStack([first, second])
            controller.pasteStackNext()
            for _ in 0..<100 where state.stackBusy { try await Task.sleep(nanoseconds: 5_000_000) }
            #expect(state.stack.map(\.id) == [second.id])
            #expect(board.string(forType: .string) == "First queued")
            #expect(environment.sentCount == 1)
            environment.isAccessibilityTrusted = false
            controller.pasteStackNext()
            for _ in 0..<100 where state.stackBusy { try await Task.sleep(nanoseconds: 5_000_000) }
            #expect(state.stack.first?.id == second.id)
            #expect(environment.sentCount == 1)
            #expect(board.string(forType: .string) == "First queued")
            state.stackTargetPID = target.processIdentifier + 1
            controller.pasteStackNext()
            #expect(state.stack.first?.id == second.id)
            #expect(state.statusMessage?.contains("target changed") == true)
        }
    }
}

@MainActor
private final class StackTestEnvironment: PasteEnvironment {
    let ownProcessIdentifier: pid_t = -1
    var frontmostProcessIdentifier: pid_t?
    var uptime: TimeInterval = 0
    var isAccessibilityTrusted = true
    var sentCount = 0
    let target: NSRunningApplication
    init(target: NSRunningApplication) { self.target = target; frontmostProcessIdentifier = target.processIdentifier }
    func requestAccessibility() -> Bool { isAccessibilityTrusted }
    func isTerminated(_ app: NSRunningApplication) -> Bool { false }
    func isActive(_ app: NSRunningApplication) -> Bool { true }
    func activate(_ app: NSRunningApplication) -> Bool { frontmostProcessIdentifier = app.processIdentifier; return true }
    func waitForActivation() async throws { uptime += 0.02; await Task.yield() }
    func sendPaste(to app: NSRunningApplication) -> Bool { sentCount += 1; return true }
}
