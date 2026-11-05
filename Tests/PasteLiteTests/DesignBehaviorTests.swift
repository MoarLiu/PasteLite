import AppKit
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct DesignBehaviorTests {
    @Test func pinsSurviveLimitChangesAndClearing() async throws {
        try await fixture { store, _, _ in
            let pinned = sample("Pinned", age: 100)
            #expect(await store.add(pinned) == .success)
            #expect(await store.togglePin(pinned) == .success)
            for value in ["One", "Two", "Three"] { #expect(await store.add(sample(value)) == .success) }
            await store.updateLimit(1)
            #expect(store.items.count == 2)
            #expect(store.items.first?.id == pinned.id)
            #expect(await store.clear() == .success)
            #expect(store.items.map(\.id) == [pinned.id])
            #expect(await store.clearIncludingPinned() == .success)
            #expect(store.items.isEmpty)
        }
    }

    @Test func undoRestoresOriginalAssetsAndPin() async throws {
        try await fixture { store, _, _ in
            let original = sample("Original")
            #expect(await store.add(original) == .success)
            #expect(await store.togglePin(original) == .success)
            #expect(await store.remove(id: original.id) == .success)
            #expect(store.items.isEmpty)
            #expect(store.deletedItem?.assets.first?.data == original.assets.first?.data)
            #expect(await store.undoDelete() == .success)
            let restored = try #require(store.items.first)
            #expect(restored.id == original.id)
            #expect(restored.isPinned)
            let loaded = try await store.resolve(restored)
            #expect(loaded.assets.map(\.data) == original.assets.map(\.data))
            #expect(loaded.assets.map(\.pasteboardType) == original.assets.map(\.pasteboardType))
            #expect(store.deletedItem == nil)
        }
    }

    @Test func pinsAndUsagePersistAcrossReloadAndRecapture() async throws {
        try await fixture { store, _, url in
            let original = sample("Remember me")
            _ = await store.add(original)
            _ = await store.togglePin(original)
            await store.recordUse(original)
            var recaptured = sample("Remember me")
            recaptured.copiedAt = Date().addingTimeInterval(1)
            _ = await store.add(recaptured)
            let reloaded = SQLiteHistoryStore(databaseURL: url)
            await reloaded.loadRecentItems()
            let item = try #require(reloaded.items.first)
            #expect(item.isPinned)
            #expect(item.useCount == 1)
            #expect(item.storedByteCount == original.assetByteCount)
            #expect(reloaded.items.count == 1)
        }
    }

    @Test func migrationKeepsExistingHistoryAndBlobs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let database = try SQLiteDatabase(url: url)
        try database.execute("""
            CREATE TABLE history_items (id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
              source_app_name TEXT, source_bundle_identifier TEXT, copied_at REAL NOT NULL,
              content_hash TEXT NOT NULL UNIQUE, preview_text TEXT NOT NULL);
            CREATE TABLE history_assets (id TEXT PRIMARY KEY, history_id TEXT NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
              item_index INTEGER NOT NULL, pasteboard_type TEXT NOT NULL, storage_kind TEXT NOT NULL DEFAULT 'blob',
              data_path TEXT, data_blob BLOB, byte_count INTEGER NOT NULL DEFAULT 0, UNIQUE(history_id,item_index,pasteboard_type));
            PRAGMA user_version = 1;
            """)
        let id = UUID()
        try database.execute("INSERT INTO history_items VALUES ('\(id)', 'Legacy', 'text', NULL, NULL, 100, 'legacy', 'Kept');")
        try database.execute("INSERT INTO history_assets VALUES ('asset', '\(id)', 0, 'public.utf8-plain-text', 'blob', NULL, X'4B657074', 4);")
        let store = SQLiteHistoryStore(databaseURL: url)
        await store.loadRecentItems()
        let item = try #require(store.items.first)
        #expect(item.title == "Legacy")
        #expect(!item.isPinned)
        #expect(item.useCount == 0)
        #expect(try await store.resolve(item).assets.first?.data == Data("Kept".utf8))
        #expect(await store.togglePin(item) == .success)
    }

    @Test func concealedContentIsMaskedAndExpires() async throws {
        try await fixture { store, board, _ in
            try await preferences { preferences in
                let monitor = ClipboardMonitor(historyStore: store, pasteboard: board, preferences: preferences)
                board.clearContents()
                let input = NSPasteboardItem()
                input.setString("Demo secret", forType: .string)
                input.setString("1", forType: .concealed)
                board.writeObjects([input])
                await monitor.checkForChanges()
                let concealed = try #require(store.items.first)
                #expect(concealed.kind == .concealed)
                #expect(concealed.title == "Concealed content")
                #expect(concealed.previewText.isEmpty)
                #expect(try await store.resolve(concealed).assets.first?.data == Data("Demo secret".utf8))
                let state = AppState()
                state.searchText = "Demo secret"
                #expect(state.filteredItems(in: store.items).isEmpty)
                var expired = sample("expired", age: 90_000)
                expired.kind = .concealed
                _ = await store.add(expired)
                await store.expireSensitive()
                #expect(!store.items.contains(where: { $0.id == expired.id }))
                await #expect(throws: HistoryItemLoadError.self) { _ = try await store.resolve(expired.metadataOnly) }
                monitor.stop()
            }
        }
    }

    @Test func pauseAndSensitiveSkipDoNotCapture() async throws {
        try await fixture { store, board, _ in
            try await preferences { preferences in
                let monitor = ClipboardMonitor(historyStore: store, pasteboard: board, preferences: preferences)
                preferences.recordingPaused = true
                board.clearContents(); board.setString("While paused", forType: .string)
                await monitor.checkForChanges()
                #expect(store.items.isEmpty)
                preferences.recordingPaused = false
                await monitor.checkForChanges()
                #expect(store.items.isEmpty)
                preferences.sensitivePolicy = .skip
                board.clearContents()
                board.setString("Hidden", forType: .string); board.setString("1", forType: .concealed)
                await monitor.checkForChanges()
                #expect(store.items.isEmpty)
                board.clearContents(); board.setString("Visible", forType: .string)
                await monitor.checkForChanges()
                #expect(store.items.first?.previewText == "Visible")
                monitor.stop()
            }
        }
    }

    @Test func plainTextCopyDropsRichRepresentations() async throws {
        try await fixture { store, board, _ in
            var item = sample("Plain text")
            item.assets.append(.init(index: 0, pasteboardType: .rtf, data: Data("{\\rtf1 Rich text}".utf8)))
            let service = PasteService(historyStore: store, pasteboard: board)
            #expect(await service.copyToClipboard(item) == .success)
            #expect(board.data(forType: .rtf) != nil)
            #expect(await service.copyToClipboard(item, plainText: true) == .success)
            #expect(board.string(forType: .string) == "Plain text")
            #expect(board.data(forType: .rtf) == nil)
        }
    }

    @Test func excludedAppsAreSkippedBeforeReadingContent() async throws {
        try await fixture { store, board, _ in
            try await preferences { prefs in
                prefs.excludedApps = ["com.example.private"]
                let monitor = ClipboardMonitor(historyStore: store, pasteboard: board, preferences: prefs,
                    sourceApplication: { ("Private App", "com.example.private") })
                board.clearContents(); board.setString("Excluded content", forType: .string)
                await monitor.checkForChanges()
                #expect(store.items.isEmpty)
                prefs.excludedApps = []
                board.clearContents(); board.setString("Allowed content", forType: .string)
                await monitor.checkForChanges()
                #expect(store.items.first?.sourceBundleIdentifier == "com.example.private")
                #expect(store.items.first?.previewText == "Allowed content")
                monitor.stop()
            }
        }
    }

    @Test func codeAndPinnedFiltersUseDesignedOrder() {
        var code = sample("ssh demo@example.local")
        code.kind = .code
        var pin = sample("Older pin", age: 100)
        pin.isPinned = true
        let state = AppState()
        #expect(state.filteredItems(in: [code, pin]).first?.id == pin.id)
        state.selectedFilter = .pinned
        #expect(state.filteredItems(in: [code, pin]).map(\.id) == [pin.id])
        state.selectedFilter = .text
        #expect(state.filteredItems(in: [code]).count == 1)
        #expect(CodeDetector.language(for: code.title) == "Shell")
        #expect(CodeDetector.language(for: "Ordinary text") == nil)
    }

    @Test func escapeClosesActionsThenSearchThenPanel() async throws {
        try await fixture { store, board, _ in
            let state = AppState()
            let controller = HistoryPanelController(appState: state, historyStore: store,
                pasteService: PasteService(historyStore: store, pasteboard: board))
            defer { controller.close() }
            let panel = try #require(controller.window as? HistoryPanel)
            state.searchText = "query"
            state.actionsPresented = true
            panel.onCancel?()
            #expect(!state.actionsPresented)
            #expect(state.searchText == "query")
            panel.onCancel?()
            #expect(state.searchText.isEmpty)
        }
    }

    @Test func preferencesPersistAllDesignChoices() async throws {
        let name = "PasteLiteDesignPreferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = AppPreferences(defaults: defaults)
        prefs.showPreview = false
        prefs.plainText = true
        prefs.position = .nearTop
        prefs.excludedApps = ["com.example.private"]
        prefs.historyLimit = 2500
        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.showPreview == false)
        #expect(reloaded.plainText)
        #expect(reloaded.position == .nearTop)
        #expect(reloaded.historyLimit == 2500)
        #expect(reloaded.excludedApps == ["com.example.private"])
    }

    @Test func updateWithoutMatchingVerifiedAssetIsRejected() async {
        let release = InstallableRelease(tag_name: "v99.0.0", html_url: URL(string: "https://github.com/MoarLiu/PasteLite")!, assets: [])
        await #expect(throws: ReleaseInstaller.InstallError.self) { _ = try await ReleaseInstaller.stage(release) }
    }

    @Test func stableAndBetaVersionsAreComparedInReleaseOrder() {
        #expect(UpdateChecker.compareVersions("v0.3.0-beta.2", "0.3.0-beta.1") == .orderedDescending)
        #expect(UpdateChecker.compareVersions("0.3.0", "0.3.0-beta.10") == .orderedDescending)
        #expect(UpdateChecker.compareVersions("0.3.0-beta.2", "0.3.0") == .orderedAscending)
        #expect(UpdateChecker.compareVersions("0.3.0+build.2", "0.3.0") == .orderedSame)
        #expect(UpdateChecker.compareVersions("0.3.0-beta.2", "0.3.0-beta.10") == .orderedAscending)
    }

    @Test func updateArchivesRejectTraversalAndSymlinks() throws {
        try ReleaseInstaller.validateArchiveEntries("PasteLite.app/\nPasteLite.app/Contents/MacOS/PasteLite", details: "-rwxr-xr-x binary")
        #expect(throws: ReleaseInstaller.InstallError.self) {
            try ReleaseInstaller.validateArchiveEntries("PasteLite.app/../../outside", details: "-rwxr-xr-x file")
        }
        #expect(throws: ReleaseInstaller.InstallError.self) {
            try ReleaseInstaller.validateArchiveEntries("/tmp/PasteLite.app/file", details: "-rwxr-xr-x file")
        }
        #expect(throws: ReleaseInstaller.InstallError.self) {
            try ReleaseInstaller.validateArchiveEntries("PasteLite.app/link", details: "lrwxr-xr-x link -> outside")
        }
    }

    @Test func clipboardRollbackPreservesPrivacyMarkers() async throws {
        try await fixture { _, board, _ in
            let item = NSPasteboardItem()
            item.setString("Private original", forType: .string)
            item.setString("1", forType: .concealed)
            board.clearContents()
            board.writeObjects([item])
            let snapshot = try #require(PasteboardSnapshot.capture(from: board))
            board.clearContents()
            board.setString("Replacement", forType: .string)
            snapshot.restore(to: board)
            #expect(board.string(forType: .string) == "Private original")
            #expect(board.types?.contains(.concealed) == true)
        }
    }
}

@MainActor private func fixture(_ body: (SQLiteHistoryStore, NSPasteboard, URL) async throws -> Void) async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLiteDesignTests-\(UUID())")
    let url = directory.appendingPathComponent("History.sqlite3")
    let board = NSPasteboard(name: .init("PasteLiteDesignTests-\(UUID())"))
    defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(databaseURL: url, limit: 10)
    await store.loadRecentItems()
    try await body(store, board, url)
}
@MainActor private func preferences(_ body: (AppPreferences) async throws -> Void) async throws {
    let name = "PasteLiteDesignPreferences-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try await body(AppPreferences(defaults: defaults))
}
private func sample(_ text: String, age: TimeInterval = 0) -> ClipboardItem {
    ClipboardItem(title: text, kind: .text, copiedAt: Date().addingTimeInterval(-age), contentHash: text,
                  previewText: text, assets: [.init(index: 0, pasteboardType: .string, data: Data(text.utf8))])
}
