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
    @Published private(set) var deletedItem: ClipboardItem?
    private var undoTask: Task<Void, Never>?
    private var deletionGeneration = 0
    private var pendingRemovals = Set<UUID>()
    private var undoToken = UUID()

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
        guard !pendingRemovals.contains(id), let original = items.first(where: { $0.id == id }) else { return .success }
        pendingRemovals.insert(id)
        defer { pendingRemovals.remove(id) }
        let generation = deletionGeneration
        let resolved: ClipboardItem
        do {
            resolved = try await resolve(original)
        }
        catch { return .failure(error.localizedDescription) }
        guard generation == deletionGeneration else { return .success }
        let mutation = await repository.remove(id: id)
        apply(mutation.snapshot)
        if mutation.result.isSuccess, generation == deletionGeneration {
            clearImageCache()
            undoTask?.cancel()
            undoToken = UUID()
            deletedItem = resolved
            undoTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.deletedItem = nil
            }
        }
        return mutation.result
    }

    @discardableResult
    func clear() async -> HistoryStoreMutationResult {
        // Invalidate captures immediately, including work still processing off the main actor.
        captureGeneration += 1
        deletionGeneration += 1
        discardUndo()
        let mutation = await repository.clear(captureGeneration: captureGeneration)
        apply(mutation.snapshot)
        if mutation.result.isSuccess {
            clearImageCache()
            captureErrorMessage = nil
        }
        return mutation.result
    }

    func discardUndo() {
        undoToken = UUID()
        undoTask?.cancel()
        undoTask = nil
        deletedItem = nil
    }

    func undoDelete() async -> HistoryStoreMutationResult {
        guard let item = deletedItem else { return .success }
        let token = undoToken
        let generation = captureGeneration
        let mutation = await repository.restore(item, generation: generation)
        apply(mutation.snapshot)
        if token == undoToken, mutation.result.isSuccess || item.isExpired { discardUndo() }
        return mutation.result
    }

    func togglePin(_ item: ClipboardItem) async -> HistoryStoreMutationResult {
        let mutation = await repository.setPinned(id: item.id, pinned: !item.isPinned)
        apply(mutation.snapshot)
        return mutation.result
    }

    func recordUse(_ item: ClipboardItem) async {
        apply((await repository.recordUse(id: item.id)).snapshot)
    }

    func updateLimit(_ limit: Int) async { apply(await repository.updateLimit(limit)) }

    func expireSensitive() async { await loadRecentItems(limit: Int.max) }

    func invalidateCaptures() { captureGeneration += 1 }

    func clearIncludingPinned() async -> HistoryStoreMutationResult {
        captureGeneration += 1
        deletionGeneration += 1
        discardUndo()
        let mutation = await repository.clear(captureGeneration: captureGeneration, includePinned: true)
        apply(mutation.snapshot)
        clearImageCache()
        return mutation.result
    }

    func resolve(_ item: ClipboardItem) async throws -> ClipboardItem {
        try Task.checkCancellation()
        guard !item.isExpired else { throw HistoryItemLoadError.unavailable }
        if item.hasLoadedAssets { return item }
        let loaded = try await repository.resolve(item)
        try Task.checkCancellation()
        guard !loaded.isExpired else { throw HistoryItemLoadError.unavailable }
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
        if let path = ProcessInfo.processInfo.environment["PASTELITE_DATA_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("History.sqlite3")
        }
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")

        return baseDirectory
            .appendingPathComponent("PasteLite", isDirectory: true)
            .appendingPathComponent("History.sqlite3")
    }
}
