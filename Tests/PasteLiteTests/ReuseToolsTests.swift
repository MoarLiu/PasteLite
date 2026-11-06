import AppKit
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct ReuseToolsTests {
    @Test func templatesPreserveOriginalAndExpandRepeatedUnicodeVariables() throws {
        let source = "Hello {{ name }}\n{{城市}} / {{name}}\n$HOME"
        let template = TextTemplate(text: source)
        #expect(template.variables == ["name", "城市"])
        #expect(try template.expand(values: ["name": "Ada", "城市": "上海"]) == "Hello Ada\n上海 / Ada\n$HOME")
        #expect(template.text == source)
        #expect(throws: LibraryError.self) { _ = try template.expand(values: ["name": "Ada"]) }
        #expect(throws: LibraryError.self) { _ = try TextTemplate(text: "{{value}}").expand(values: ["value": String(repeating: "x", count: 1048577)]) }
    }

    @Test func scriptReadsStdinReturnsUTF8AndRejectsFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("transform.sh")
        try Data("tr '[:lower:]' '[:upper:]'\n".utf8).write(to: script)
        let runner = TextScriptRunner()
        #expect(try await runner.run(script: script, input: "abc 中文\n") == "ABC 中文\n")
        try Data("printf 'intentional failure' >&2\nexit 7\n".utf8).write(to: script)
        await #expect(throws: LibraryError.self) { _ = try await runner.run(script: script, input: "test") }
        try Data("while :; do :; done\n".utf8).write(to: script)
        let task = Task { try await runner.run(script: script, input: "test") }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func authenticatedMCPListsToolsAndOmitsConcealedHistory() async throws {
        try await libraryFixture { store, _, _ in
            _ = await store.add(librarySample("Visible query content"))
            var secret = librarySample("Never expose this secret")
            secret.kind = .concealed
            _ = await store.add(secret)
            let server = LocalMCPServer()
            server.start(store: store)
            defer { server.stop() }
            for _ in 0..<100 where server.endpoint == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            let url = try #require(server.endpoint.flatMap(URL.init(string:)))
            let token = try #require(server.token)
            func request(_ method: String, params: [String: Any] = [:], authenticated: Bool = true) async throws -> (Data, Int) {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
                let (data, response) = try await URLSession.shared.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            #expect(try await request("tools/list", authenticated: false).1 == 403)
            var get = URLRequest(url: url)
            get.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, getResponse) = try await URLSession.shared.data(for: get)
            #expect((getResponse as? HTTPURLResponse)?.statusCode == 405)
            let initialized = try await request("initialize", params: ["protocolVersion": "2025-03-26"])
            #expect(initialized.1 == 200)
            #expect(String(decoding: initialized.0, as: UTF8.self).contains("protocolVersion"))
            let tools = try await request("tools/list")
            #expect(String(decoding: tools.0, as: UTF8.self).contains("search_saved"))
            let result = try await request("tools/call", params: ["name": "search_history", "arguments": ["query": ""]])
            let text = String(decoding: result.0, as: UTF8.self)
            #expect(text.contains("Visible query content"))
            #expect(!text.contains("Never expose"))
            let rejected = try await request("tools/call", params: ["name": "delete_history"])
            #expect(String(decoding: rejected.0, as: UTF8.self).contains("error"))
        }
    }

    @Test func folderSyncPropagatesEditsDeletionAndRejectsOldResurrection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = HistoryRepository(databaseURL: directory.appendingPathComponent("a.sqlite3"), limit: 500)
        let b = HistoryRepository(databaseURL: directory.appendingPathComponent("b.sqlite3"), limit: 500)
        _ = try await a.configureFolderSync(enabled: true)
        _ = try await b.configureFolderSync(enabled: true)
        let firstDraft = snippetDraft(name: "Shared", body: "First", generation: 0)
        let added = await a.saveLibrary(firstDraft)
        #expect(added.result.isSuccess)
        let initial = try #require(try await a.syncOutbox().first)
        _ = try await a.configureFolderSync(enabled: true)
        #expect(try await a.syncOutbox().count == 1)
        let event = try JSONDecoder().decode(LibrarySyncEvent.self, from: initial.data)
        let received = try await b.applySyncEvent(event, generation: 0)
        let original = try #require(received.libraryItems.first)
        #expect(original.content.previewText == "First")
        var edit = firstDraft
        edit.editingID = original.id; edit.expectedRevision = original.revision; edit.name = "Edited"; edit.body = "Second"
        #expect(await b.saveLibrary(edit).result.isSuccess)
        let updates = try await b.syncOutbox()
        for update in updates {
            _ = try await a.applySyncEvent(JSONDecoder().decode(LibrarySyncEvent.self, from: update.data), generation: 0)
        }
        #expect(await a.loadLibrary().libraryItems.first?.content.previewText == "Second")
        _ = await b.removeLibraryItem(id: original.id)
        let all = try await b.syncOutbox().map { try JSONDecoder().decode(LibrarySyncEvent.self, from: $0.data) }.sorted { $0.stamp < $1.stamp }
        for update in all { _ = try await a.applySyncEvent(update, generation: 0) }
        #expect(await a.loadLibrary().libraryItems.isEmpty)
        // A new receipt ID must not allow an old upsert to defeat a tombstone.
        var replay = event; replay.id = UUID()
        #expect(try await a.applySyncEvent(replay, generation: 0).libraryItems.isEmpty)
        _ = await a.clearLibrary(generation: 1)
        let unknownSource = HistoryRepository(databaseURL: directory.appendingPathComponent("c.sqlite3"), limit: 500)
        _ = try await unknownSource.configureFolderSync(enabled: true)
        _ = await unknownSource.saveLibrary(snippetDraft(name: "Old unseen item", body: "Content", generation: 0))
        let unknown = try #require(try await unknownSource.syncOutbox().first)
        var unseen = try JSONDecoder().decode(LibrarySyncEvent.self, from: unknown.data)
        unseen.stamp = event.stamp
        #expect(try await a.applySyncEvent(unseen, generation: 1).libraryItems.isEmpty)
    }

    @Test func syncFilesAreIdempotentAndFailedApplyRollsBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = HistoryRepository(databaseURL: directory.appendingPathComponent("a.sqlite3"), limit: 500)
        let bURL = directory.appendingPathComponent("b.sqlite3")
        let b = HistoryRepository(databaseURL: bURL, limit: 500)
        _ = try await a.configureFolderSync(enabled: true)
        _ = await b.loadLibrary()
        _ = await a.saveLibrary(snippetDraft(name: "Incoming", body: "Original payload", generation: 0))
        let entry = try #require(try await a.syncOutbox().first)
        let files = FolderSyncFiles()
        let folder = directory.appendingPathComponent("shared")
        try await files.write([entry], folder: folder)
        try await files.write([entry], folder: folder)
        let paths = try await files.list(folder: folder)
        #expect(paths.count == 1)
        let event = try await files.read(try #require(paths.first))
        let db = try SQLiteDatabase(url: bURL)
        try db.execute("CREATE TRIGGER fail_sync BEFORE INSERT ON library_assets BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        await #expect(throws: (any Error).self) { _ = try await b.applySyncEvent(event, generation: 0) }
        #expect(await b.loadLibrary().libraryItems.isEmpty)
        #expect(try await !b.hasReceivedSync(event.id))
        try db.execute("DROP TRIGGER fail_sync;")
        #expect(try await b.applySyncEvent(event, generation: 0).libraryItems.count == 1)
        #expect(try await b.applySyncEvent(event, generation: 0).libraryItems.count == 1)
    }

    @Test func concurrentSnapshotSavesConvergeOnOneStableIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = HistoryRepository(databaseURL: directory.appendingPathComponent("a.sqlite3"), limit: 500)
        let b = HistoryRepository(databaseURL: directory.appendingPathComponent("b.sqlite3"), limit: 500)
        _ = try await a.configureFolderSync(enabled: true)
        _ = try await b.configureFolderSync(enabled: true)
        let source = librarySample("Same original")
        _ = await a.saveLibrary(snapshotDraft(source, name: "Device A", generation: 0))
        _ = await b.saveLibrary(snapshotDraft(source, name: "Device B", generation: 0))
        let aEvents = try await a.syncOutbox(), bEvents = try await b.syncOutbox()
        for entry in aEvents { _ = try await b.applySyncEvent(JSONDecoder().decode(LibrarySyncEvent.self, from: entry.data), generation: 0) }
        for entry in bEvents { _ = try await a.applySyncEvent(JSONDecoder().decode(LibrarySyncEvent.self, from: entry.data), generation: 0) }
        let aItems = await a.loadLibrary().libraryItems, bItems = await b.loadLibrary().libraryItems
        #expect(aItems.count == 1 && bItems.count == 1)
        #expect(aItems.first?.id == bItems.first?.id)
        #expect(aItems.first?.name == bItems.first?.name)
        let winner = try #require(aItems.first)
        _ = await a.removeLibraryItem(id: winner.id)
        let oldLoser = try (aEvents + bEvents).map { try JSONDecoder().decode(LibrarySyncEvent.self, from: $0.data) }.first { $0.archive.items.first?.id != winner.id }
        var replay = try #require(oldLoser); replay.id = UUID()
        #expect(try await a.applySyncEvent(replay, generation: 0).libraryItems.isEmpty)
    }

    @Test func sameNamedOfflineGroupsConvergeAndFolderChangeResetsReceipts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = HistoryRepository(databaseURL: directory.appendingPathComponent("a.sqlite3"), limit: 500)
        let b = HistoryRepository(databaseURL: directory.appendingPathComponent("b.sqlite3"), limit: 500)
        _ = try await a.configureFolderSync(enabled: true, folder: "folder-one")
        _ = try await b.configureFolderSync(enabled: true, folder: "folder-one")
        _ = await a.createLibraryGroup(name: "Work", generation: 0)
        _ = await b.createLibraryGroup(name: "Work", generation: 0)
        let aEvents = try await a.syncOutbox(), bEvents = try await b.syncOutbox()
        for entry in aEvents { _ = try await b.applySyncEvent(JSONDecoder().decode(LibrarySyncEvent.self, from: entry.data), generation: 0) }
        for entry in bEvents { _ = try await a.applySyncEvent(JSONDecoder().decode(LibrarySyncEvent.self, from: entry.data), generation: 0) }
        let ag = await a.loadLibrary().libraryGroups, bg = await b.loadLibrary().libraryGroups
        #expect(Dictionary(uniqueKeysWithValues: ag.map { ($0.id, $0.name) }) == Dictionary(uniqueKeysWithValues: bg.map { ($0.id, $0.name) }))
        _ = try await a.configureFolderSync(enabled: true, folder: "folder-two")
        #expect(try await !a.hasReceivedSync(try #require(bEvents.first?.id)))
        let fresh = try await a.syncOutbox()
        #expect(fresh.count == 1)
        #expect(try JSONDecoder().decode(LibrarySyncEvent.self, from: fresh[0].data).archive.groups.count == 2)
        _ = try await a.configureFolderSync(enabled: false)
        #expect(try await a.syncOutbox().isEmpty)
    }

    @Test func cancellingScriptAlsoStopsBackgroundChildren() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("child.sh")
        try Data("(sleep 1; printf leaked > late-output) &\nwait\n".utf8).write(to: script)
        let runner = TextScriptRunner()
        let task = Task { try await runner.run(script: script, input: "text") }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-output").path))
    }

    @Test func itemEditDoesNotRecreateDeletedGroup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = HistoryRepository(databaseURL: directory.appendingPathComponent("a.sqlite3"), limit: 500)
        let b = HistoryRepository(databaseURL: directory.appendingPathComponent("b.sqlite3"), limit: 500)
        _ = try await a.configureFolderSync(enabled: true)
        _ = try await b.configureFolderSync(enabled: true)
        let group = try #require(await a.createLibraryGroup(name: "Work", generation: 0).snapshot.libraryGroups.first)
        var draft = snippetDraft(name: "Snippet", body: "Original", generation: 0); draft.groupID = group.id
        let item = try #require(await a.saveLibrary(draft).snapshot.libraryItems.first)
        for entry in try await a.syncOutbox() {
            _ = try await b.applySyncEvent(JSONDecoder().decode(LibrarySyncEvent.self, from: entry.data), generation: 0)
        }
        _ = await b.deleteLibraryGroup(id: group.id)
        draft.editingID = item.id; draft.expectedRevision = item.revision; draft.body = "Edited offline"
        _ = await a.saveLibrary(draft)
        let events = try await a.syncOutbox().map { try JSONDecoder().decode(LibrarySyncEvent.self, from: $0.data) }.sorted { $0.stamp < $1.stamp }
        for event in events { _ = try await b.applySyncEvent(event, generation: 0) }
        let result = await b.loadLibrary()
        #expect(result.libraryGroups.isEmpty)
        #expect(result.libraryItems.first?.groupID == nil)
        #expect(result.libraryItems.first?.content.previewText == "Edited offline")
    }
}
