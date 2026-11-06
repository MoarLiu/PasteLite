import AppKit
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct LibraryRepositoryTests {
    @Test func savedPayloadSurvivesSourceDeletionPruningAndRecapture() async throws {
        try await libraryFixture { store, _, _ in
            var source = librarySample("original")
            source.assets.append(.init(index: 0, pasteboardType: .html, data: Data("<b>original</b>".utf8)))
            _ = await store.add(source)
            let savedID = try #require(await store.saveLibrary(snapshotDraft(source, name: "My alias", generation: store.libraryGeneration)).itemID)
            _ = await store.remove(id: source.id)
            await store.updateLimit(1)
            _ = await store.add(librarySample("new"))
            var recaptured = librarySample("original")
            recaptured.contentHash = source.contentHash
            _ = await store.add(recaptured)
            let saved = try #require(store.libraryItems.first(where: { $0.id == savedID }))
            #expect(saved.name == "My alias")
            #expect(saved.id != source.id)
            let loaded = try await store.resolve(saved.displayItem)
            #expect(loaded.assets.map(\.data) == source.assets.sorted { $0.pasteboardType.rawValue < $1.pasteboardType.rawValue }.map(\.data))
            #expect(loaded.origin == .library)
        }
    }

    @Test func duplicateSnapshotPreservesNameAndGroup() async throws {
        try await libraryFixture { store, _, _ in
            let groupID = try #require(await store.createGroup("Work").itemID)
            let source = librarySample("Command")
            _ = await store.add(source)
            var draft = snapshotDraft(source, name: "Deployment", generation: store.libraryGeneration)
            draft.groupID = groupID
            let id = try #require(await store.saveLibrary(draft).itemID)
            draft.name = "Replacement"
            draft.groupID = nil
            #expect(await store.saveLibrary(draft).itemID == id)
            #expect(store.libraryItems.count == 1)
            #expect(store.libraryItems.first?.name == "Deployment")
            #expect(store.libraryItems.first?.groupID == groupID)
        }
    }

    @Test func snippetEditsKeepWhitespaceAndOriginalContent() async throws {
        try await libraryFixture { store, _, url in
            let source = librarySample("Original history")
            _ = await store.add(source)
            var draft = snippetDraft(name: "需求整理", body: "  第一行\n\nSecond line\n", generation: store.libraryGeneration)
            draft.source = source
            let id = try #require(await store.saveLibrary(draft).itemID)
            let initial = try #require(store.libraryItems.first)
            draft.editingID = id; draft.expectedRevision = initial.revision
            draft.kind = .code; draft.body = "\nlet value = 42\n\n"
            #expect(await store.saveLibrary(draft).result == .success)
            let updated = try #require(store.libraryItems.first)
            #expect(updated.revision == initial.revision + 1)
            #expect(updated.content.kind == .code)
            #expect(updated.content.previewText == draft.body)
            #expect(try await store.resolve(updated.displayItem).assets.first?.data == Data(draft.body.utf8))
            #expect(try await store.resolve(source.metadataOnly).assets.first?.data == source.assets.first?.data)
            let reloaded = SQLiteHistoryStore(databaseURL: url)
            await reloaded.loadRecentItems()
            #expect(reloaded.libraryItems.first?.name == "需求整理")
            #expect(reloaded.libraryItems.first?.content.previewText == draft.body)
        }
    }

    @Test func sameSnippetBodyCanHaveDifferentNames() async throws {
        try await libraryFixture { store, _, _ in
            for name in ["Work", "Personal"] {
                #expect(await store.saveLibrary(snippetDraft(name: name, body: "Same text", generation: store.libraryGeneration)).result == .success)
            }
            #expect(store.libraryItems.count == 2)
        }
    }

    @Test func sourcePrunedWhileNamingCanStillBeSaved() async throws {
        try await libraryFixture { store, _, _ in
            let source = librarySample("Editor owns a snapshot")
            _ = await store.add(source)
            let loaded = try await store.resolve(source.metadataOnly)
            await store.updateLimit(1)
            _ = await store.add(librarySample("Newer capture"))
            #expect(!store.items.contains(where: { $0.id == source.id }))
            #expect(await store.saveLibrary(snapshotDraft(loaded, name: "Keep", generation: store.libraryGeneration)).result == .success)
            #expect(try await store.resolve(try #require(store.libraryItems.first).displayItem).assets.first?.data == source.assets.first?.data)
        }
    }

    @Test func oneMebibyteSnippetRoundTrips() async throws {
        try await libraryFixture { store, _, _ in
            let body = String(repeating: "x", count: LibraryValidation.snippetByteLimit)
            #expect(await store.saveLibrary(snippetDraft(name: "Boundary", body: body, generation: store.libraryGeneration)).result == .success)
            let item = try #require(store.libraryItems.first)
            #expect(try await store.resolve(item.displayItem).assets.first?.data.count == LibraryValidation.snippetByteLimit)
        }
    }

    @Test func groupValidationMoveAndDeletePreserveItems() async throws {
        try await libraryFixture { store, _, _ in
            let id = try #require(await store.createGroup(" Work ").itemID)
            #expect(!((await store.createGroup("work")).result.isSuccess))
            #expect(!((await store.createGroup("Ungrouped")).result.isSuccess))
            #expect(!((await store.createGroup(String(repeating: "A", count: 41))).result.isSuccess))
            var draft = snippetDraft(name: "Kept", body: "Keep this", generation: store.libraryGeneration)
            draft.groupID = id
            _ = await store.saveLibrary(draft)
            let group = try #require(store.libraryGroups.first)
            #expect(await store.renameGroup(group, name: "Project A") == .success)
            #expect(await store.deleteGroup(group) == .success)
            #expect(store.libraryGroups.isEmpty)
            let item = try #require(store.libraryItems.first)
            #expect(item.groupID == nil)
            #expect(try await store.resolve(item.displayItem).assets.first?.data == Data("Keep this".utf8))
        }
    }

    @Test func libraryUseDoesNotMoveSavedTimeOrCreateHistory() async throws {
        try await libraryFixture { store, _, _ in
            _ = await store.saveLibrary(snippetDraft(name: "A", body: "snippet", generation: store.libraryGeneration))
            let item = try #require(store.libraryItems.first)
            await store.recordUse(item.displayItem)
            #expect(store.items.isEmpty)
            #expect(store.libraryItems.first?.savedAt == item.savedAt)
            #expect(store.libraryItems.first?.lastUsedAt != nil)
            #expect(store.libraryItems.first?.content.useCount == 1)
        }
    }

    @Test func clearingHistoryKeepsLibraryAndClearingLibraryKeepsHistory() async throws {
        try await libraryFixture { store, _, _ in
            _ = await store.add(librarySample("History"))
            _ = await store.saveLibrary(snippetDraft(name: "Saved", body: "Library", generation: store.libraryGeneration))
            _ = await store.createGroup("Group")
            #expect(await store.clear() == .success)
            #expect(store.items.isEmpty)
            #expect(store.libraryItems.count == 1)
            _ = await store.add(librarySample("Retained"))
            #expect(await store.clearLibrary() == .success)
            #expect(store.libraryItems.isEmpty)
            #expect(store.libraryGroups.isEmpty)
            #expect(store.items.count == 1)
        }
    }

    @Test func allDataClearIsAtomicAndInvalidatesEditor() async throws {
        try await libraryFixture { store, database, _ in
            _ = await store.add(librarySample("History"))
            _ = await store.saveLibrary(snippetDraft(name: "Saved", body: "Library", generation: store.libraryGeneration))
            let draft = snippetDraft(name: "Stale", body: "Must not return", generation: store.libraryGeneration)
            try database.execute("CREATE TRIGGER fail_library_delete BEFORE DELETE ON library_items BEGIN SELECT RAISE(ABORT, 'injected'); END;")
            #expect(!(await store.clearIncludingPinned()).isSuccess)
            #expect(store.items.count == 1)
            #expect(store.libraryItems.count == 1)
            try database.execute("DROP TRIGGER fail_library_delete;")
            #expect(await store.clearIncludingPinned() == .success)
            #expect(!(await store.saveLibrary(draft).result.isSuccess))
            #expect(store.items.isEmpty && store.libraryItems.isEmpty)
        }
    }

    @Test func undoKeepsPayloadOnFailureAndCanRetry() async throws {
        try await libraryFixture { store, database, _ in
            _ = await store.saveLibrary(snippetDraft(name: "Saved", body: "Original data", generation: store.libraryGeneration))
            let original = try #require(store.libraryItems.first)
            #expect(await store.removeLibraryItem(id: original.id) == .success)
            #expect(store.hasUndoDeletion)
            try database.execute("CREATE TRIGGER fail_library_restore BEFORE INSERT ON library_items BEGIN SELECT RAISE(ABORT, 'injected'); END;")
            #expect(!(await store.undoDelete()).isSuccess)
            #expect(store.deletedLibraryItem?.id == original.id)
            try database.execute("DROP TRIGGER fail_library_restore;")
            #expect(await store.undoDelete() == .success)
            #expect(try await store.resolve(try #require(store.libraryItems.first).displayItem).assets.first?.data == Data("Original data".utf8))
            #expect(!store.hasUndoDeletion)
            _ = await store.removeLibraryItem(id: original.id)
            _ = await store.clearLibrary()
            #expect(await store.undoDelete() == .success)
            #expect(store.libraryItems.isEmpty)
        }
    }

    @Test func failedUpdateRollsBackOriginalNameAndAssets() async throws {
        try await libraryFixture { store, database, _ in
            var draft = snippetDraft(name: "Initial", body: "Original", generation: store.libraryGeneration)
            _ = await store.saveLibrary(draft)
            let item = try #require(store.libraryItems.first)
            draft.editingID = item.id; draft.expectedRevision = item.revision
            draft.name = "Changed"; draft.body = "Replacement"
            try database.execute("CREATE TRIGGER fail_library_write BEFORE INSERT ON library_assets BEGIN SELECT RAISE(ABORT, 'injected'); END;")
            #expect(!(await store.saveLibrary(draft).result.isSuccess))
            #expect(store.libraryItems.first?.name == "Initial")
            #expect(try await store.resolve(item.displayItem).assets.first?.data == Data("Original".utf8))
            try database.execute("DROP TRIGGER fail_library_write;")
            #expect(await store.saveLibrary(draft).result == .success)
        }
    }

    @Test func editedContentRejectsStaleResolution() async throws {
        try await libraryFixture { store, _, _ in
            var draft = snippetDraft(name: "Initial", body: "Original", generation: store.libraryGeneration)
            _ = await store.saveLibrary(draft)
            let old = try #require(store.libraryItems.first)
            draft.editingID = old.id; draft.expectedRevision = old.revision; draft.body = "New text"
            _ = await store.saveLibrary(draft)
            await #expect(throws: LibraryError.self) { _ = try await store.resolve(old.displayItem) }
            #expect(!(await store.saveLibrary(draft).result.isSuccess))
        }
    }

    @Test func concealedAndOversizedSnippetsAreRejected() async throws {
        try await libraryFixture { store, _, _ in
            var secret = librarySample("Secret")
            secret.kind = .concealed
            _ = await store.add(secret)
            #expect(!(await store.saveLibrary(snapshotDraft(secret, name: "Secret", generation: store.libraryGeneration)).result.isSuccess))
            #expect(!(await store.saveLibrary(snippetDraft(name: "Huge", body: String(repeating: "x", count: LibraryValidation.snippetByteLimit + 1), generation: store.libraryGeneration)).result.isSuccess))
            #expect(!(await store.saveLibrary(snippetDraft(name: "Empty", body: " \n ", generation: store.libraryGeneration)).result.isSuccess))
            #expect(store.libraryItems.isEmpty)
        }
    }

    @Test func memoryFallbackNeverClaimsPermanentSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteHistoryStore(databaseURL: directory)
        await store.loadRecentItems()
        #expect(!store.isLibraryAvailable)
        #expect(await store.add(librarySample("Memory history")) == .success)
        #expect(!(await store.saveLibrary(snippetDraft(name: "Saved", body: "Not durable", generation: store.libraryGeneration)).result.isSuccess))
        #expect(store.libraryItems.isEmpty)
    }

    @Test func pausingCaptureDoesNotInvalidateLibraryDraft() async throws {
        try await libraryFixture { store, _, _ in
            let draft = snippetDraft(name: "Draft", body: "Keep editing", generation: store.libraryGeneration)
            store.invalidateCaptures()
            #expect(await store.saveLibrary(draft).result == .success)
            #expect(store.libraryItems.count == 1)
        }
    }

    @Test func storageCanBeRetriedWithoutLosingMemoryHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite3")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = SQLiteHistoryStore(databaseURL: url)
        await store.loadRecentItems()
        let source = librarySample("Memory item")
        _ = await store.add(source)
        try FileManager.default.removeItem(at: url)
        await store.retryStorage()
        #expect(store.isLibraryAvailable)
        #expect(store.storageWarning == nil)
        #expect(store.items.map(\.id) == [source.id])
        #expect(await store.saveLibrary(snapshotDraft(source, name: "Recovered", generation: store.libraryGeneration)).result == .success)
    }

    @Test func migrationFailureRollsBackPinsAndCanRetry() async throws {
        try await libraryFixture { store, database, url in
            let source = librarySample("Legacy")
            _ = await store.add(source)
            _ = await store.togglePin(source)
            try database.execute("""
                PRAGMA user_version = 3;
                CREATE TRIGGER fail_migration BEFORE INSERT ON library_assets
                BEGIN SELECT RAISE(ABORT, 'migration failure'); END;
                """)
            let failing = SQLiteHistoryStore(databaseURL: url)
            await failing.loadRecentItems()
            #expect(!failing.isLibraryAvailable)
            let version = try database.prepare("PRAGMA user_version;")
            #expect(try version.step())
            #expect(version.columnInt64(at: 0) == 3)
            let pins = try database.prepare("SELECT is_pinned FROM history_items WHERE id = ?;")
            try pins.bind(source.id.uuidString, at: 1)
            #expect(try pins.step())
            #expect(pins.columnInt64(at: 0) == 1)
            try database.execute("DROP TRIGGER fail_migration;")
            await failing.retryStorage()
            #expect(failing.isLibraryAvailable)
            #expect(failing.libraryItems.count == 1)
            #expect(try await failing.resolve(try #require(failing.libraryItems.first).displayItem).assets.first?.data == source.assets.first?.data)
        }
    }

    @Test(arguments: [1, 2, 3])
    func legacyMigrationPreservesDataAndIsIdempotent(version: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite3")
        let database = try SQLiteDatabase(url: url)
        try database.execute("""
            CREATE TABLE history_items (id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
              source_app_name TEXT, source_bundle_identifier TEXT, copied_at REAL NOT NULL,
              content_hash TEXT NOT NULL UNIQUE, preview_text TEXT NOT NULL,
              is_pinned INTEGER NOT NULL DEFAULT 0, use_count INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE history_assets (id TEXT PRIMARY KEY, history_id TEXT NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
              item_index INTEGER NOT NULL, pasteboard_type TEXT NOT NULL, storage_kind TEXT NOT NULL DEFAULT 'blob',
              data_path TEXT, data_blob BLOB, byte_count INTEGER NOT NULL DEFAULT 0, UNIQUE(history_id,item_index,pasteboard_type));
            PRAGMA user_version = \(version);
            """)
        let id = UUID(), secretID = UUID()
        let now = Date().timeIntervalSince1970
        try database.execute("INSERT INTO history_items VALUES ('\(id)', 'Legacy pin', 'text', 'Notes', NULL, \(now), 'legacy', 'Kept', 1, 7);")
        try database.execute("INSERT INTO history_items VALUES ('\(secretID)', 'Concealed content', 'concealed', NULL, NULL, \(now), 'legacy-secret', '', 1, 0);")
        try database.execute("INSERT INTO history_assets VALUES ('asset', '\(id)', 0, 'public.utf8-plain-text', 'blob', NULL, X'4B657074', 4);")
        let store = SQLiteHistoryStore(databaseURL: url)
        await store.loadRecentItems()
        let saved = try #require(store.libraryItems.first)
        #expect(saved.sourceHistoryID == id)
        #expect(saved.content.useCount == 7)
        #expect(saved.groupID == nil)
        #expect(try await store.resolve(saved.displayItem).assets.first?.data == Data("Kept".utf8))
        #expect(store.items.contains(where: { $0.id == id && !$0.isPinned }))
        #expect(store.items.contains(where: { $0.id == secretID && $0.isPinned && $0.expiresAt != nil }))
        let reloaded = SQLiteHistoryStore(databaseURL: url)
        await reloaded.loadRecentItems()
        #expect(reloaded.libraryItems.map(\.id) == [saved.id])
        let query = try database.prepare("PRAGMA user_version;")
        #expect(try query.step())
        #expect(query.columnInt64(at: 0) == 4)
    }
}

@MainActor
func libraryFixture(_ body: (SQLiteHistoryStore, SQLiteDatabase, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLiteLibrary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("History.sqlite3")
    let store = SQLiteHistoryStore(databaseURL: url)
    await store.loadRecentItems()
    let database = try SQLiteDatabase(url: url)
    try await body(store, database, url)
    store.discardUndo()
}

func librarySample(_ text: String) -> ClipboardItem {
    let assets: [ClipboardAsset] = [.init(index: 0, pasteboardType: .string, data: Data(text.utf8))]
    return ClipboardItem(title: text, kind: .text, sourceAppName: "Notes", contentHash: ClipboardContentHasher.hash(assets: assets), previewText: text, assets: assets)
}

func snippetDraft(name: String, body: String, generation: Int) -> LibraryDraft {
    LibraryDraft(type: .snippet, name: name, body: body, kind: .text, generation: generation)
}

func snapshotDraft(_ source: ClipboardItem, name: String, generation: Int) -> LibraryDraft {
    LibraryDraft(type: .snapshot, name: name, body: "", kind: source.kind, source: source, generation: generation)
}
