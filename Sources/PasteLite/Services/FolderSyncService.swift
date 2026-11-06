import Foundation
import Combine
import AppKit

actor FolderSyncFiles {
    func write(_ entries: [(id: UUID, data: Data)], folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for entry in entries {
            try Task.checkCancellation()
            let target = folder.appendingPathComponent(entry.id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: target.path) {
                guard try Data(contentsOf: target) == entry.data else { throw LibraryError.invalid("A sync event file changed unexpectedly.") }
                continue
            }
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
            _ = FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file = try FileHandle(forWritingTo: temporary)
            do { try file.write(contentsOf: entry.data); try file.synchronize(); try file.close() }
            catch { try? file.close(); throw error }
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    func list(folder: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        guard files.count <= 100000 else { throw LibraryError.invalid("This sync folder has too many change files.") }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func read(_ url: URL) throws -> LibrarySyncEvent {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let size = values.fileSize, size <= LibraryArchive.maximumBytes else { throw LibraryError.invalid("Invalid sync file size or link.") }
        let data = try Data(contentsOf: url)
        guard data.count <= LibraryArchive.maximumBytes else { throw LibraryError.invalid("Sync file exceeds 256 MiB.") }
        let event = try JSONDecoder().decode(LibrarySyncEvent.self, from: data)
        guard event.id.uuidString.lowercased() == url.deletingPathExtension().lastPathComponent.lowercased() else { throw LibraryError.invalid("Sync file identity mismatch.") }
        return event
    }
}

@MainActor
final class FolderSyncService: ObservableObject {
    static let shared = FolderSyncService()
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    private let files = FolderSyncFiles()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var session = UUID()
    private var store: SQLiteHistoryStore?
    private var storeObserver: AnyCancellable?
    private var observedGeneration = 0

    func start(store: SQLiteHistoryStore) {
        stop()
        guard !AppPreferences.shared.syncFolder.isEmpty else { return }
        self.store = store
        observedGeneration = store.libraryGeneration
        storeObserver = store.$snapshotRevision.dropFirst().sink { [weak self, weak store] _ in
            guard let self, let store, self.observedGeneration != store.libraryGeneration else { return }
            self.observedGeneration = store.libraryGeneration
            self.task?.cancel()
        }
        let session = self.session
        let folder = AppPreferences.shared.syncFolder
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.configureFolderSync(enabled: true, folder: folder)
                guard !Task.isCancelled, self.session == session else { return }
                self.task = nil
                self.syncNow()
                self.timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.syncNow() }
                }
            } catch { if self.session == session { self.message = error.localizedDescription; self.task = nil } }
        }
    }

    func stop() {
        session = UUID(); task?.cancel(); task = nil
        timer?.invalidate(); timer = nil; busy = false; store = nil
        storeObserver = nil
    }

    func syncNow() {
        guard task == nil, let store, !AppPreferences.shared.syncFolder.isEmpty else { return }
        let folder = URL(fileURLWithPath: AppPreferences.shared.syncFolder).appendingPathComponent("PasteLite-Sync", isDirectory: true)
        let generation = store.libraryGeneration, session = self.session
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.session == session { self.busy = false; self.task = nil } }
            do {
                let outbox = try await store.syncOutbox()
                try Task.checkCancellation()
                guard session == self.session, generation == store.libraryGeneration else { return }
                try await self.files.write(outbox, folder: folder)
                try Task.checkCancellation()
                guard session == self.session, generation == store.libraryGeneration else { return }
                for entry in outbox {
                    try Task.checkCancellation()
                    guard session == self.session, generation == store.libraryGeneration else { return }
                    try await store.acknowledgeSync(entry.id)
                }
                let urls = try await self.files.list(folder: folder)
                var pending: [(stamp: String, url: URL)] = []
                for url in urls {
                    try Task.checkCancellation()
                    guard session == self.session, generation == store.libraryGeneration else { return }
                    guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), try await !store.hasReceivedSync(id) else { continue }
                    let event = try await self.files.read(url)
                    pending.append((event.stamp, url))
                }
                for entry in pending.sorted(by: { $0.stamp < $1.stamp }) {
                    try Task.checkCancellation()
                    guard session == self.session, generation == store.libraryGeneration else { return }
                    let event = try await self.files.read(entry.url)
                    try Task.checkCancellation()
                    guard session == self.session, generation == store.libraryGeneration else { return }
                    try await store.applySyncEvent(event, generation: generation)
                }
                self.message = "Saved library is up to date."
            } catch is CancellationError { }
            catch { if self.session == session { self.message = "Sync failed: \(error.localizedDescription)" } }
        }
    }

    func chooseFolder(store: SQLiteHistoryStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a shared folder such as iCloud Drive. Saved text, images and edits will be shared as readable JSON; deletions propagate. Anyone with folder access can read or modify them. History is not shared."
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            AppPreferences.shared.syncFolder = url.path
            self.start(store: store)
        }
    }

    func disable(store: SQLiteHistoryStore) {
        stop(); AppPreferences.shared.syncFolder = ""
        Task {
            do { try await store.configureFolderSync(enabled: false); message = "Sync disabled. Existing shared files remain in the selected folder." }
            catch { message = error.localizedDescription }
        }
    }
}
