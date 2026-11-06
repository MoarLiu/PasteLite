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
    var actionGeneration: Int { get }
    func loadRecentItems(limit: Int) async
    @discardableResult func add(_ item: ClipboardItem) async -> HistoryStoreMutationResult
    @discardableResult func addCaptured(_ item: ClipboardItem, generation: Int) async -> HistoryStoreMutationResult
    func reportCaptureError(_ message: String?)
    @discardableResult func remove(id: ClipboardItem.ID) async -> HistoryStoreMutationResult
    @discardableResult func clear() async -> HistoryStoreMutationResult
    func resolve(_ item: ClipboardItem) async throws -> ClipboardItem
    func isCurrent(_ item: ClipboardItem) -> Bool
}

@MainActor
extension HistoryStore {
    func isCurrent(_ item: ClipboardItem) -> Bool { true }
    var captureGeneration: Int { 0 }
    var actionGeneration: Int { captureGeneration }

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
    @Published private(set) var libraryItems: [LibraryItem] = []
    @Published private(set) var libraryGroups: [LibraryGroup] = []
    @Published private(set) var isLibraryAvailable = false
    @Published private(set) var libraryErrorMessage: String?
    @Published private(set) var snapshotRevision = 0
    @Published private(set) var ocrBusyKeys = Set<String>()
    @Published private(set) var ocrErrors: [String: String] = [:]
    private var ocrTasks: [String: Task<Void, Never>] = [:]
    private(set) var captureGeneration = 0
    private(set) var libraryGeneration = 0
    var actionGeneration: Int { captureGeneration + libraryGeneration }
    private let repository: HistoryRepository
    private var appliedRevision = 0
    private var imageCacheGeneration = 0
    private let imageCache = NSCache<NSString, NSImage>()
    @Published private(set) var deletedItem: ClipboardItem?
    @Published private(set) var deletedLibraryItem: LibraryItem?
    var hasUndoDeletion: Bool { deletedItem != nil || deletedLibraryItem != nil }
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
        if mutation.result.isSuccess, generation == captureGeneration {
            captureErrorMessage = nil
            if item.kind == .image { recognizeText(in: item) }
        }
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
            deletedLibraryItem = nil
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
        libraryGeneration += 1
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
        deletedLibraryItem = nil
    }

    func undoDelete() async -> HistoryStoreMutationResult {
        if let item = deletedLibraryItem {
            let token = undoToken
            let mutation = await repository.restoreLibrary(item, generation: libraryGeneration)
            apply(mutation.snapshot)
            if token == undoToken, mutation.result.isSuccess { discardUndo() }
            return mutation.result
        }
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
        if item.origin == .library { apply((await repository.recordLibraryUse(id: item.id)).snapshot) }
        else { apply((await repository.recordUse(id: item.id)).snapshot) }
    }

    func loadLibrary() async { apply(await repository.loadLibrary()) }
    func retryStorage() async { apply(await repository.retryStorage()) }

    func configureFolderSync(enabled: Bool, folder: String? = nil) async throws { apply(try await repository.configureFolderSync(enabled: enabled, folder: folder)) }
    func syncOutbox() async throws -> [(id: UUID, data: Data)] { try await repository.syncOutbox() }
    func acknowledgeSync(_ id: UUID) async throws { try await repository.acknowledgeSync(id) }
    func hasReceivedSync(_ id: UUID) async throws -> Bool { try await repository.hasReceivedSync(id) }
    func applySyncEvent(_ event: LibrarySyncEvent, generation: Int) async throws {
        guard generation == libraryGeneration else { throw LibraryError.cleared }
        apply(try await repository.applySyncEvent(event, generation: generation))
        clearImageCache()
    }

    func recognizeText(in item: ClipboardItem, force: Bool = false) {
        guard item.kind == .image, ocrTasks[item.ocrKey] == nil,
              force || !item.hasRecognizedText else { return }
        let key = item.ocrKey
        let historyGeneration = captureGeneration, savedGeneration = libraryGeneration
        ocrBusyKeys.insert(key)
        ocrErrors[key] = nil
        ocrTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { self.ocrTasks[key] = nil; self.ocrBusyKeys.remove(key) }
            do {
                let loaded = try await self.repository.resolve(item)
                guard let data = ClipboardImageProcessor.imageData(in: loaded.assets) else { throw HistoryItemLoadError.unavailable }
                let text = try await OCRService.shared.recognize(data)
                try Task.checkCancellation()
                guard historyGeneration == self.captureGeneration, savedGeneration == self.libraryGeneration else { return }
                self.apply(try await self.repository.saveRecognizedText(text, item: item,
                          historyGeneration: historyGeneration, savedGeneration: savedGeneration))
            } catch is CancellationError { }
            catch {
                if historyGeneration == self.captureGeneration, savedGeneration == self.libraryGeneration {
                    self.ocrErrors[key] = error.localizedDescription
                }
            }
        }
    }

    func cancelRecognition(for item: ClipboardItem) { ocrTasks[item.ocrKey]?.cancel() }

    func exportLibrary(to url: URL) async throws { try await repository.exportLibrary(to: url) }

    func importLibrary(from url: URL) async throws -> (added: Int, skipped: Int) {
        let generation = libraryGeneration
        let archive = try await Task.detached(priority: .userInitiated) { try LibraryArchive.read(from: url) }.value
        try Task.checkCancellation()
        guard generation == libraryGeneration else { throw LibraryError.cleared }
        let result = try await repository.importLibrary(archive, generation: generation)
        apply(result.snapshot)
        clearImageCache()
        return (result.added, result.skipped)
    }

    func saveLibrary(_ draft: LibraryDraft) async -> LibraryMutation {
        let mutation = await repository.saveLibrary(draft)
        apply(mutation.snapshot)
        if mutation.result.isSuccess { clearImageCache() }
        return mutation
    }

    func createGroup(_ name: String) async -> LibraryMutation {
        let generation = libraryGeneration
        let mutation = await repository.createLibraryGroup(name: name, generation: generation)
        apply(mutation.snapshot)
        return mutation
    }

    func renameGroup(_ group: LibraryGroup, name: String) async -> HistoryStoreMutationResult {
        let mutation = await repository.renameLibraryGroup(id: group.id, name: name)
        apply(mutation.snapshot)
        return mutation.result
    }

    func deleteGroup(_ group: LibraryGroup) async -> HistoryStoreMutationResult {
        let mutation = await repository.deleteLibraryGroup(id: group.id)
        apply(mutation.snapshot)
        return mutation.result
    }

    func moveLibraryItem(_ item: LibraryItem, groupID: UUID?) async -> HistoryStoreMutationResult {
        let generation = libraryGeneration
        let mutation = await repository.moveLibraryItem(id: item.id, groupID: groupID, generation: generation)
        apply(mutation.snapshot)
        return mutation.result
    }

    func removeLibraryItem(id: UUID) async -> HistoryStoreMutationResult {
        guard !pendingRemovals.contains(id), var original = libraryItems.first(where: { $0.id == id }) else { return .success }
        pendingRemovals.insert(id)
        defer { pendingRemovals.remove(id) }
        let generation = deletionGeneration
        do {
            let loaded = try await resolve(original.displayItem)
            original.content.assets = loaded.assets
            original.content.hasLoadedAssets = true
        } catch { return .failure(error.localizedDescription) }
        guard generation == deletionGeneration else { return .success }
        let mutation = await repository.removeLibraryItem(id: id)
        apply(mutation.snapshot)
        if mutation.result.isSuccess, generation == deletionGeneration {
            clearImageCache()
            discardUndo()
            deletedLibraryItem = original
            undoTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                self?.deletedLibraryItem = nil
            }
        }
        return mutation.result
    }

    func clearLibrary() async -> HistoryStoreMutationResult {
        libraryGeneration += 1
        deletionGeneration += 1
        discardUndo()
        let mutation = await repository.clearLibrary(generation: libraryGeneration)
        apply(mutation.snapshot)
        if mutation.result.isSuccess { clearImageCache() }
        return mutation.result
    }

    func savedSnapshot(for item: ClipboardItem) -> LibraryItem? {
        libraryItems.first { $0.type == .snapshot && $0.sourceContentHash == item.contentHash }
    }

    func updateLimit(_ limit: Int) async { apply(await repository.updateLimit(limit)) }

    func expireSensitive() async { await loadRecentItems(limit: Int.max) }

    func invalidateCaptures() { captureGeneration += 1 }

    func clearIncludingPinned() async -> HistoryStoreMutationResult {
        captureGeneration += 1
        libraryGeneration += 1
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
        if item.hasLoadedAssets, item.origin == .history { return item }
        let loaded = try await repository.resolve(item)
        try Task.checkCancellation()
        guard !loaded.isExpired else { throw HistoryItemLoadError.unavailable }
        return loaded
    }

    func isCurrent(_ item: ClipboardItem) -> Bool {
        guard !item.isExpired else { return false }
        if item.origin == .library {
            return libraryItems.contains { $0.id == item.id && $0.revision == item.contentRevision && $0.content.contentHash == item.contentHash }
        }
        return items.contains { $0.id == item.id && $0.contentHash == item.contentHash }
    }

    func image(for item: ClipboardItem, maxPixelSize: Int) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(item.origin):\(item.id):\(item.contentHash):\(item.contentRevision):\(maxPixelSize)" as NSString
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
        libraryItems = snapshot.libraryItems
        libraryGroups = snapshot.libraryGroups
        isLibraryAvailable = snapshot.isLibraryAvailable
        libraryErrorMessage = snapshot.libraryErrorMessage
        snapshotRevision = snapshot.revision
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
