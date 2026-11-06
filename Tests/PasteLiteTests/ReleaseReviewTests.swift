import AppKit
import LinkPresentation
import CryptoKit
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct ReleaseReviewTests {
    @Test(arguments: [false, true])
    func concealedCopyKeepsProtection(plainText: Bool) async throws {
        try await fixture { store, board, _ in
            let service = PasteService(historyStore: store, pasteboard: board)
            #expect(await service.copyToClipboard(secret("Review sample"), plainText: plainText) == .success)
            #expect(board.string(forType: .string) == "Review sample")
            #expect(board.types?.contains(.concealed) == true)
            #expect(board.pasteboardItems?.allSatisfy { $0.types.contains(.concealed) } == true)
        }
    }

    @Test func expiredLoadedContentCannotBeCopiedOrResolved() async throws {
        try await fixture { store, board, _ in
            let expired = secret("Expired sample", age: 90_000)
            board.clearContents(); board.setString("Keep original clipboard", forType: .string)
            let service = PasteService(historyStore: store, pasteboard: board)
            #expect(!(await service.copyToClipboard(expired)).isSuccess)
            #expect(board.string(forType: .string) == "Keep original clipboard")
            await #expect(throws: HistoryItemLoadError.self) { _ = try await store.resolve(expired) }
            #expect(!(await store.add(expired)).isSuccess)
        }
    }

    @Test func richTextOnlyCaptureSupportsPlainTextCopy() async throws {
        try await fixture { store, board, _ in
            let assets = [ClipboardAsset(index: 0, pasteboardType: .rtf, data: Data("{\\rtf1\\ansi Review sample}".utf8))]
            let item = try #require(ClipboardItemFactory.make(assets: assets, nativeColorHex: nil,
                sourceAppName: "Review", sourceBundleIdentifier: nil, copiedAt: Date()))
            #expect(item.previewText == "Review sample")
            let service = PasteService(historyStore: store, pasteboard: board)
            #expect(await service.copyToClipboard(item, plainText: true) == .success)
            #expect(board.string(forType: .string) == "Review sample")
            #expect(board.data(forType: .rtf) == nil)
        }
    }

    @Test(arguments: [ClipboardKind.link, .color, .file])
    func nativeRepresentationsConvertToPlainText(kind: ClipboardKind) async throws {
        try await fixture { store, board, _ in
            let value: String
            let asset: ClipboardAsset
            switch kind {
            case .link:
                value = "https://example.com/review"
                asset = .init(index: 0, pasteboardType: .URL, data: Data(value.utf8))
            case .color:
                value = "#336699"
                asset = .init(index: 0, pasteboardType: .color, data: Data("Native representation fixture".utf8))
            default:
                value = "/tmp/review file.txt"
                asset = .init(index: 0, pasteboardType: .fileURL, data: Data(URL(fileURLWithPath: value).absoluteString.utf8))
            }
            let item = ClipboardItem(title: value, kind: kind, contentHash: value, previewText: value, assets: [asset])
            let service = PasteService(historyStore: store, pasteboard: board)
            #expect(await service.copyToClipboard(item, plainText: true) == .success)
            #expect(board.string(forType: .string) == value)
            #expect(board.data(forType: asset.pasteboardType) == nil)
        }
    }

    @Test(arguments: [false, true])
    func staleRestoreCannotResurrectClearedHistory(memoryOnly: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let url = memoryOnly ? blocker.appendingPathComponent("history.sqlite3") : directory.appendingPathComponent("history.sqlite3")
        let repository = HistoryRepository(databaseURL: url, limit: 10)
        let item = sample("Deleted before clear")
        _ = await repository.add(item)
        _ = await repository.remove(id: item.id)
        _ = await repository.clear(captureGeneration: 1)
        let restored = await repository.restore(item, generation: 0)
        #expect(restored.snapshot.items.isEmpty)
        #expect(await repository.loadRecentItems(limit: 10).items.isEmpty)
    }

    @Test func undoDoesNotReplaceANewerRecapture() async throws {
        try await fixture { store, _, _ in
            let original = sample("Same content", age: 60)
            _ = await store.add(original)
            _ = await store.remove(id: original.id)
            let recaptured = sample("Same content")
            _ = await store.add(recaptured)
            #expect(await store.undoDelete() == .success)
            #expect(store.items.count == 1)
            #expect(store.items.first?.id == recaptured.id)
        }
    }

    @Test func failedPinMutationRollsBackItsDatabaseChange() async throws {
        try await fixture { store, _, url in
            let original = sample("Pin transaction")
            _ = await store.add(original)
            let database = try SQLiteDatabase(url: url)
            try database.execute("""
                CREATE TRIGGER block_review_prune BEFORE DELETE ON history_items
                BEGIN SELECT RAISE(ABORT, 'Review fixture'); END;
                """)
            _ = await store.togglePin(original)
            // Unpin would require pruning the oldest record at the new limit.
            let pinned = try #require(store.items.first)
            for value in ["Newer one", "Newer two"] { _ = await store.add(sample(value)) }
            await store.updateLimit(1)
            let result = await store.togglePin(pinned)
            #expect(!result.isSuccess)
            let statement = try database.prepare("SELECT is_pinned FROM history_items WHERE id = ?;")
            try statement.bind(original.id.uuidString, at: 1)
            #expect(try statement.step())
            #expect(statement.columnInt64(at: 0) == 1)
        }
    }

    @Test func concurrentDeletesDoNotReplaceUndoWithAnEmptyItem() async throws {
        try await fixture { store, _, _ in
            let original = sample("Delete once")
            _ = await store.add(original)
            async let first = store.remove(id: original.id)
            async let second = store.remove(id: original.id)
            let results = await [first, second]
            #expect(results.allSatisfy { $0.isSuccess })
            #expect(store.deletedItem?.id == original.id)
            #expect(await store.undoDelete() == .success)
            #expect(store.items.map(\.id) == [original.id])
        }
    }

    @Test func clearWinsOverAConcurrentDelete() async throws {
        try await fixture { store, _, _ in
            let original = sample("Clear wins")
            _ = await store.add(original)
            async let removal = store.remove(id: original.id)
            async let clearing = store.clear()
            _ = await [removal, clearing]
            #expect(store.items.isEmpty)
            #expect(store.deletedItem == nil)
            #expect(await store.undoDelete() == .success)
            #expect(store.items.isEmpty)
        }
    }

    @Test func aCancelledRevealCannotOverwriteTheNextSelection() async throws {
        let first = secret("First sample"), second = secret("Second sample")
        let gate = RevealGate(first)
        let model = ConcealedRevealModel()
        model.show(first) { _ in await gate.load() }
        let oldTask = model.loadTask
        await gate.waitUntilStarted()
        model.reset()
        model.show(second) { $0 }
        await model.loadTask?.value
        #expect(model.text == "Second sample")
        await gate.release()
        await oldTask?.value
        #expect(model.text == "Second sample")
        model.reset()
        #expect(model.text == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func revealingContentStopsAtItsExpiry() async throws {
        let clock = ExpiryClock()
        let model = ConcealedRevealModel(waitUntilExpiry: { seconds in
            await clock.wait(seconds: seconds)
        })
        model.show(secret("Expiring sample", age: 86398)) { $0 }
        await model.loadTask?.value
        #expect(model.text == "Expiring sample")

        let seconds = await clock.startedSeconds()
        #expect(seconds > 0 && seconds <= 2)
        await clock.advance()
        await model.expiryTask?.value
        #expect(model.text == nil)
    }

    @Test func websiteMetadataSnapshotDoesNotShareMutableProviderState() async throws {
        let original = LPLinkMetadata()
        let imageData = Data("Preview image representation".utf8)
        original.originalURL = URL(string: "https://example.com/original")
        original.url = URL(string: "https://example.com/final")
        original.title = "Preview fixture"
        original.imageProvider = NSItemProvider(item: imageData as NSData,
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue)
        let snapshot = try #require(WebsiteMetadataSnapshot(original))
        original.title = "Changed after capture"

        let decoded = try #require(snapshot.take())
        #expect(decoded !== original)
        #expect(decoded.originalURL == original.originalURL)
        #expect(decoded.url == original.url)
        #expect(decoded.title == "Preview fixture")
        #expect(snapshot.take() == nil)
        #expect(WebsiteMetadataSnapshot(nil) == nil)
        let imageProvider = try #require(decoded.imageProvider)
        let restoredImage: Data = try await withCheckedThrowingContinuation { continuation in
            imageProvider.loadDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.png.rawValue) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        #expect(restoredImage == imageData)
    }

    @Test func websiteMetadataRequiresOptInAndRejectsURLCredentials() {
        let url = URL(string: "https://example.com/path")!
        #expect(!WebsitePreviewPolicy.permits(url, enabled: false))
        #expect(WebsitePreviewPolicy.permits(url, enabled: true))
        #expect(!WebsitePreviewPolicy.permits(URL(string: "https://review-user@example.com")!, enabled: true))
        #expect(!WebsitePreviewPolicy.permits(URL(fileURLWithPath: "/tmp/example.html"), enabled: true))
    }

    @Test func dismissingActionsOutsideClosesANonKeyPanel() async throws {
        try await fixture { store, board, _ in
            let state = AppState()
            let controller = HistoryPanelController(appState: state, historyStore: store,
                pasteService: PasteService(historyStore: store, pasteboard: board))
            defer { controller.close() }
            let panel = try #require(controller.window as? HistoryPanel)
            panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            panel.orderFrontRegardless()
            state.actionsPresented = true
            panel.onResignKey?()
            #expect(panel.isVisible)
            state.actionsPresented = false
            for _ in 0..<20 where panel.isVisible { try await Task.sleep(nanoseconds: 5_000_000) }
            #expect(!panel.isVisible)
        }
    }

    private func fixture(_ body: (SQLiteHistoryStore, NSPasteboard, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLiteReview-\(UUID())")
        let url = directory.appendingPathComponent("history.sqlite3")
        let board = NSPasteboard(name: .init("PasteLiteReview-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteHistoryStore(databaseURL: url)
        await store.loadRecentItems()
        try await body(store, board, url)
    }
}

private actor ExpiryClock {
    private var seconds: TimeInterval?
    private var expiry: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<TimeInterval, Never>?

    func wait(seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            self.seconds = seconds
            expiry = continuation
            started?.resume(returning: seconds)
            started = nil
        }
    }

    func startedSeconds() async -> TimeInterval {
        if let seconds { return seconds }
        return await withCheckedContinuation { started = $0 }
    }

    func advance() {
        expiry?.resume()
        expiry = nil
    }
}

private actor RevealGate {
    let item: ClipboardItem
    var continuation: CheckedContinuation<ClipboardItem, Never>?
    var started: CheckedContinuation<Void, Never>?
    var hasStarted = false
    init(_ item: ClipboardItem) { self.item = item }
    func load() async -> ClipboardItem {
        hasStarted = true
        started?.resume(); started = nil
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { continuation?.resume(returning: item); continuation = nil }
}

private func sample(_ text: String, age: TimeInterval = 0) -> ClipboardItem {
    ClipboardItem(title: text, kind: .text, copiedAt: Date().addingTimeInterval(-age),
                  expiresAt: Date().addingTimeInterval(86400 - age), contentHash: text,
                  previewText: text, assets: [.init(index: 0, pasteboardType: .string, data: Data(text.utf8))])
}
private func secret(_ text: String, age: TimeInterval = 0) -> ClipboardItem {
    var item = sample(text, age: age)
    item.kind = .concealed; item.title = "Concealed content"; item.previewText = ""
    item.expiresAt = item.copiedAt.addingTimeInterval(86400)
    return item
}
