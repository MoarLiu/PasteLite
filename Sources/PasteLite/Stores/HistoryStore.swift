import AppKit
import Foundation

enum HistoryStoreMutationResult: Equatable, Sendable {
    case success
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

@MainActor
protocol HistoryStore: AnyObject, ObservableObject {
    var items: [ClipboardItem] { get }
    var captureGeneration: Int { get }
    func loadRecentItems(limit: Int) async
    @discardableResult func add(_ item: ClipboardItem) async -> HistoryStoreMutationResult
    @discardableResult func addCaptured(_ item: ClipboardItem, generation: Int) async -> HistoryStoreMutationResult
    func reportCaptureError(_ message: String?)
    @discardableResult func remove(id: ClipboardItem.ID) async -> HistoryStoreMutationResult
    @discardableResult func clear() async -> HistoryStoreMutationResult
    func resolve(_ item: ClipboardItem) async throws -> ClipboardItem
}

@MainActor
extension HistoryStore {
    var captureGeneration: Int { 0 }

    func addCaptured(_ item: ClipboardItem, generation: Int) async -> HistoryStoreMutationResult {
        guard generation == captureGeneration else { return .success }
        return await add(item)
    }

    func reportCaptureError(_ message: String?) {}

    func loadRecentItems() async {
        await loadRecentItems(limit: SQLiteHistoryStore.defaultLimit)
    }
}

@MainActor
final class SQLiteHistoryStore: HistoryStore {
    nonisolated static let defaultLimit = 500

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var storageWarning: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var captureErrorMessage: String?
    @Published private(set) var isLoading = true
    private(set) var captureGeneration = 0
    private let repository: HistoryRepository
    private var appliedRevision = 0
    private var imageCacheGeneration = 0
    private let imageCache = NSCache<NSString, NSImage>()

    init(databaseURL: URL = PasteLiteDatabasePaths.historyDatabaseURL, limit: Int = SQLiteHistoryStore.defaultLimit) {
        repository = HistoryRepository(databaseURL: databaseURL, limit: limit)
        imageCache.totalCostLimit = 32 * 1024 * 1024
        Task { [weak self] in
            await self?.loadRecentItems(limit: limit)
        }
    }

    func loadRecentItems(limit: Int) async {
        apply(await repository.loadRecentItems(limit: limit))
    }

    @discardableResult
    func add(_ item: ClipboardItem) async -> HistoryStoreMutationResult {
        let mutation = await repository.add(item)
        apply(mutation.snapshot)
        return mutation.result
    }

    func addCaptured(_ item: ClipboardItem, generation: Int) async -> HistoryStoreMutationResult {
        guard generation == captureGeneration else { return .success }
        let mutation = await repository.add(item, captureGeneration: generation)
        apply(mutation.snapshot)
        if mutation.result.isSuccess, generation == captureGeneration { captureErrorMessage = nil }
        return mutation.result
    }

    func reportCaptureError(_ message: String?) {
        captureErrorMessage = message
    }

    @discardableResult
    func remove(id: ClipboardItem.ID) async -> HistoryStoreMutationResult {
        let mutation = await repository.remove(id: id)
        apply(mutation.snapshot)
        if mutation.result.isSuccess { clearImageCache() }
        return mutation.result
    }

    @discardableResult
    func clear() async -> HistoryStoreMutationResult {
        // Invalidate captures immediately, including work still processing off the main actor.
        captureGeneration += 1
        let mutation = await repository.clear(captureGeneration: captureGeneration)
        apply(mutation.snapshot)
        if mutation.result.isSuccess {
            clearImageCache()
            captureErrorMessage = nil
        }
        return mutation.result
    }

    func resolve(_ item: ClipboardItem) async throws -> ClipboardItem {
        try Task.checkCancellation()
        if item.hasLoadedAssets { return item }
        let loaded = try await repository.resolve(item)
        try Task.checkCancellation()
        return loaded
    }

    func image(for item: ClipboardItem, maxPixelSize: Int) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(item.id):\(item.contentHash):\(maxPixelSize)" as NSString
        if let image = imageCache.object(forKey: key) { return image }
        let generation = imageCacheGeneration
        guard let thumbnail = try? await repository.thumbnail(for: item, maxPixelSize: maxPixelSize),
              !Task.isCancelled, generation == imageCacheGeneration,
              let image = NSImage(data: thumbnail.data) else { return nil }
        imageCache.setObject(image, forKey: key, cost: thumbnail.pixelWidth * thumbnail.pixelHeight * 4)
        return image
    }

    private func clearImageCache() {
        imageCacheGeneration += 1
        imageCache.removeAllObjects()
    }

    private func apply(_ snapshot: HistorySnapshot) {
        // Actor calls can resume on the main actor out of order.
        guard snapshot.revision > appliedRevision else { return }
        appliedRevision = snapshot.revision
        items = snapshot.items
        storageWarning = snapshot.storageWarning
        errorMessage = snapshot.errorMessage
        isLoading = false
    }
}

enum PasteLiteDatabasePaths {
    static var historyDatabaseURL: URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")

        return baseDirectory
            .appendingPathComponent("PasteLite", isDirectory: true)
            .appendingPathComponent("History.sqlite3")
    }
}
