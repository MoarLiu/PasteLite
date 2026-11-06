import AppKit
import Foundation
import os

struct HistorySnapshot: Sendable {
    var revision: Int
    var items: [ClipboardItem]
    var storageWarning: String?
    var errorMessage: String?
}

struct HistoryMutation: Sendable {
    var result: HistoryStoreMutationResult
    var snapshot: HistorySnapshot
}

enum HistoryItemLoadError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "This clipboard item is no longer available."
    }
}

// Only this actor opens or uses the SQLite connection. AppKit pasteboard access
// remains on the main actor, while storage and image decoding are serialized here.
actor HistoryRepository {
    private static let logger = Logger(subsystem: "com.xia.PasteLite", category: "history-store")
    private let databaseURL: URL
    private var limit: Int
    private let memoryByteLimit = 64 * 1024 * 1024
    private var database: SQLiteDatabase?
    private var didOpen = false
    private var items: [ClipboardItem] = []
    private var revision = 0
    private var captureGeneration = 0
    private var storageWarning: String?
    private var errorMessage: String?

    init(databaseURL: URL, limit: Int) {
        self.databaseURL = databaseURL
        self.limit = max(1, limit)
    }

    private func openIfNeeded() {
        guard !didOpen else { return }
        didOpen = true
        do {
            let database = try SQLiteDatabase(
                url: databaseURL,
                privateDirectory: databaseURL == PasteLiteDatabasePaths.historyDatabaseURL
            )
            try migrate(database)
            self.database = database
        } catch {
            storageWarning = "History is stored in memory only and will be lost when PasteLite quits. Older items may be removed when memory is full."
            Self.logger.warning("History is using memory only: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadRecentItems(limit requestedLimit: Int) -> HistorySnapshot {
        openIfNeeded()
        if let database {
            do {
                try expireSensitive(database: database)
                items = try fetchRecentItems(limit: min(max(1, requestedLimit), limit), database: database)
                errorMessage = nil
            } catch {
                record(error, message: "Could not load clipboard history.")
            }
        } else { pruneMemory() }
        return snapshot()
    }

    func add(_ item: ClipboardItem, captureGeneration generation: Int? = nil) -> HistoryMutation {
        // Check on the SQLite actor too: a capture may already be queued when Clear runs.
        if let generation, generation < captureGeneration {
            return HistoryMutation(result: .success, snapshot: snapshot())
        }
        openIfNeeded()
        guard !item.isExpired else {
            return HistoryMutation(result: .failure("This concealed item has expired."), snapshot: snapshot())
        }
        guard item.hasLoadedAssets, !item.assets.isEmpty else {
            let message = "Could not save a clipboard item without its original data."
            errorMessage = message
            return HistoryMutation(result: .failure(message), snapshot: snapshot())
        }
        var item = item
        if let existing = items.first(where: { $0.contentHash == item.contentHash }) {
            item.isPinned = existing.isPinned
            item.useCount = existing.useCount
        }
        if let database {
            do {
                var updatedItems: [ClipboardItem] = []
                try withTransaction(database: database) {
                    try expireSensitive(database: database)
                    let existing = try database.prepare("SELECT is_pinned, use_count FROM history_items WHERE content_hash = ?;")
                    try existing.bind(item.contentHash, at: 1)
                    if try existing.step() {
                        item.isPinned = existing.columnInt64(at: 0) != 0
                        item.useCount = Int(existing.columnInt64(at: 1))
                    }
                    try deleteItem(contentHash: item.contentHash, database: database)
                    try insert(item, database: database)
                    try pruneHistory(database: database)
                    updatedItems = try fetchRecentItems(limit: limit, database: database)
                }
                items = updatedItems
            } catch {
                return failure(error, message: "Could not save this clipboard item to history.")
            }
        } else {
            items.removeAll { $0.contentHash == item.contentHash }
            items.insert(item, at: 0)
            pruneMemory()
            var bytes = items.reduce(0) { $0 + $1.assetByteCount }
            while bytes > memoryByteLimit, let oldest = items.popLast() {
                bytes -= oldest.assetByteCount
            }
        }
        errorMessage = nil
        return HistoryMutation(result: .success, snapshot: snapshot())
    }

    func restore(_ item: ClipboardItem, generation: Int) -> HistoryMutation {
        openIfNeeded()
        guard generation >= captureGeneration else {
            return HistoryMutation(result: .success, snapshot: snapshot())
        }
        // A newer copy of the same content already restores its availability.
        if let database {
            do {
                let statement = try database.prepare("SELECT 1 FROM history_items WHERE content_hash = ?;")
                try statement.bind(item.contentHash, at: 1)
                if try statement.step() { return HistoryMutation(result: .success, snapshot: snapshot()) }
            } catch { return failure(error, message: "Could not restore this clipboard item.") }
        } else if items.contains(where: { $0.contentHash == item.contentHash }) {
            return HistoryMutation(result: .success, snapshot: snapshot())
        }
        return add(item, captureGeneration: generation)
    }

    func remove(id: UUID) -> HistoryMutation {
        openIfNeeded()
        if let database {
            do {
                let statement = try database.prepare("DELETE FROM history_items WHERE id = ?;")
                try statement.bind(id.uuidString, at: 1)
                try statement.run()
            } catch {
                return failure(error, message: "Could not remove this clipboard item from history.")
            }
        }
        items.removeAll { $0.id == id }
        errorMessage = nil
        return HistoryMutation(result: .success, snapshot: snapshot())
    }

    func clear(captureGeneration generation: Int? = nil, includePinned: Bool = false) -> HistoryMutation {
        captureGeneration = generation.map { max(captureGeneration, $0) } ?? (captureGeneration + 1)
        openIfNeeded()
        if let database {
            do {
                try database.execute(includePinned ? "DELETE FROM history_items;" : "DELETE FROM history_items WHERE is_pinned = 0;")
            } catch {
                return failure(error, message: "Could not clear clipboard history.")
            }
        }
        items.removeAll { includePinned || !$0.isPinned }
        errorMessage = nil
        return HistoryMutation(result: .success, snapshot: snapshot())
    }

    func resolve(_ item: ClipboardItem) throws -> ClipboardItem {
        try Task.checkCancellation()
        openIfNeeded()
        guard !item.isExpired else {
            throw HistoryItemLoadError.unavailable
        }
        if let database {
            let assets = try fetchAssets(historyID: item.id, database: database)
            guard !assets.isEmpty else { throw HistoryItemLoadError.unavailable }
            var loaded = item
            loaded.assets = assets
            loaded.hasLoadedAssets = true
            return loaded
        }
        guard let loaded = items.first(where: { $0.id == item.id }) else {
            throw HistoryItemLoadError.unavailable
        }
        return loaded
    }

    func setPinned(id: UUID, pinned: Bool) -> HistoryMutation {
        openIfNeeded()
        if let database {
            do {
                var updated: [ClipboardItem] = []
                try withTransaction(database: database) {
                    let statement = try database.prepare("UPDATE history_items SET is_pinned = ? WHERE id = ?;")
                    try statement.bind(Int64(pinned ? 1 : 0), at: 1)
                    try statement.bind(id.uuidString, at: 2)
                    try statement.run()
                    try pruneHistory(database: database)
                    updated = try fetchRecentItems(limit: limit, database: database)
                }
                items = updated
            } catch { return failure(error, message: "Could not update this pin.") }
        } else if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isPinned = pinned
            pruneMemory()
        }
        errorMessage = nil
        return HistoryMutation(result: .success, snapshot: snapshot())
    }

    func recordUse(id: UUID) -> HistoryMutation {
        openIfNeeded()
        let copiedAt = Date()
        if let database {
            do {
                var updatedItems: [ClipboardItem] = []
                try withTransaction(database: database) {
                    let statement = try database.prepare("UPDATE history_items SET copied_at = ?, use_count = use_count + 1 WHERE id = ?;")
                    try statement.bind(copiedAt.timeIntervalSince1970, at: 1)
                    try statement.bind(id.uuidString, at: 2)
                    try statement.run()
                    updatedItems = try fetchRecentItems(limit: limit, database: database)
                }
                items = updatedItems
            } catch { return failure(error, message: "Could not update this clipboard item's recent use.") }
        } else if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].copiedAt = copiedAt
            items[index].useCount += 1
            items.sort {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.copiedAt > $1.copiedAt
            }
        }
        errorMessage = nil
        return HistoryMutation(result: .success, snapshot: snapshot())
    }

    func updateLimit(_ newLimit: Int) -> HistorySnapshot {
        limit = max(1, newLimit)
        openIfNeeded()
        if let database {
            do {
                try pruneHistory(database: database)
                items = try fetchRecentItems(limit: limit, database: database)
            } catch { record(error, message: "Could not update the history limit.") }
        } else { pruneMemory() }
        return snapshot()
    }

    private func pruneMemory() {
        items.sort { $0.copiedAt > $1.copiedAt }
        var count = 0
        items.removeAll {
            if $0.isExpired { return true }
            if $0.isPinned { return false }
            count += 1
            return count > limit
        }
    }

    private func expireSensitive(database: SQLiteDatabase) throws {
        let statement = try database.prepare("DELETE FROM history_items WHERE kind = 'concealed' AND COALESCE(expires_at, copied_at + 86400) <= ?;")
        try statement.bind(Date().timeIntervalSince1970, at: 1)
        try statement.run()
    }

    func thumbnail(for item: ClipboardItem, maxPixelSize: Int) throws -> ClipboardThumbnail? {
        try Task.checkCancellation()
        openIfNeeded()
        let data: Data?
        if item.hasLoadedAssets {
            data = ClipboardImageProcessor.imageData(in: item.assets)
        } else if let database {
            // Fetch one image representation, without reading every BLOB for the item.
            let statement = try database.prepare("""
                SELECT data_blob FROM history_assets
                WHERE history_id = ? AND storage_kind = 'blob'
                  AND pasteboard_type IN (?, ?, ?)
                ORDER BY CASE pasteboard_type WHEN ? THEN 0 WHEN ? THEN 1 ELSE 2 END, item_index
                LIMIT 1;
                """)
            try statement.bind(item.id.uuidString, at: 1)
            try statement.bind(NSPasteboard.PasteboardType.png.rawValue, at: 2)
            try statement.bind(NSPasteboard.PasteboardType.tiff.rawValue, at: 3)
            try statement.bind(NSPasteboard.PasteboardType.legacyTIFF.rawValue, at: 4)
            try statement.bind(NSPasteboard.PasteboardType.png.rawValue, at: 5)
            try statement.bind(NSPasteboard.PasteboardType.tiff.rawValue, at: 6)
            data = try statement.step() ? statement.columnData(at: 0) : nil
        } else {
            data = items.first(where: { $0.id == item.id }).flatMap {
                ClipboardImageProcessor.imageData(in: $0.assets)
            }
        }
        guard let data else { return nil }
        try Task.checkCancellation()
        let thumbnail = ClipboardImageProcessor.thumbnail(from: data, maxPixelSize: maxPixelSize)
        try Task.checkCancellation()
        return thumbnail
    }

    private func snapshot() -> HistorySnapshot {
        revision += 1
        return HistorySnapshot(revision: revision, items: items.map(\.metadataOnly), storageWarning: storageWarning, errorMessage: errorMessage)
    }

    private func record(_ error: Error, message: String) {
        errorMessage = message
        Self.logger.error("\(message, privacy: .public) \(error.localizedDescription, privacy: .public)")
    }

    private func failure(_ error: Error, message: String) -> HistoryMutation {
        record(error, message: message)
        return HistoryMutation(result: .failure(message), snapshot: snapshot())
    }

    // Keep transaction orchestration and callbacks on this actor. The low-level
    // connection never receives a closure capturing actor-owned state.
    private func withTransaction(database: SQLiteDatabase, _ body: () throws -> Void) throws {
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private func migrate(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS history_items (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                kind TEXT NOT NULL,
                source_app_name TEXT,
                source_bundle_identifier TEXT,
                copied_at REAL NOT NULL,
                expires_at REAL,
                content_hash TEXT NOT NULL UNIQUE,
                preview_text TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_history_items_copied_at
                ON history_items(copied_at DESC);

            CREATE TABLE IF NOT EXISTS history_assets (
                id TEXT PRIMARY KEY,
                history_id TEXT NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
                item_index INTEGER NOT NULL,
                pasteboard_type TEXT NOT NULL,
                storage_kind TEXT NOT NULL DEFAULT 'blob',
                data_path TEXT,
                data_blob BLOB,
                byte_count INTEGER NOT NULL DEFAULT 0,
                UNIQUE(history_id, item_index, pasteboard_type)
            );

            CREATE INDEX IF NOT EXISTS idx_history_assets_history_id
                ON history_assets(history_id, item_index, pasteboard_type);

            """
        )
        let columns = try database.prepare("PRAGMA table_info(history_items);")
        var names = Set<String>()
        while try columns.step() { if let name = columns.columnString(at: 1) { names.insert(name) } }
        try withTransaction(database: database) {
            if !names.contains("is_pinned") { try database.execute("ALTER TABLE history_items ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0;") }
            if !names.contains("use_count") { try database.execute("ALTER TABLE history_items ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0;") }
            if !names.contains("expires_at") { try database.execute("ALTER TABLE history_items ADD COLUMN expires_at REAL;") }
            try database.execute("UPDATE history_items SET expires_at = copied_at + 86400 WHERE kind = 'concealed' AND expires_at IS NULL;")
            try database.execute("PRAGMA user_version = 3;")
        }
    }

    private func insert(_ item: ClipboardItem, database: SQLiteDatabase) throws {
        let itemStatement = try database.prepare(
            """
            INSERT INTO history_items (
                id,
                title,
                kind,
                source_app_name,
                source_bundle_identifier,
                copied_at,
                expires_at,
                content_hash,
                preview_text, is_pinned, use_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try itemStatement.bind(item.id.uuidString, at: 1)
        try itemStatement.bind(item.title, at: 2)
        try itemStatement.bind(item.kind.rawValue, at: 3)
        try itemStatement.bind(item.sourceAppName, at: 4)
        try itemStatement.bind(item.sourceBundleIdentifier, at: 5)
        try itemStatement.bind(item.copiedAt.timeIntervalSince1970, at: 6)
        if let expiresAt = item.expiresAt {
            try itemStatement.bind(expiresAt.timeIntervalSince1970, at: 7)
        } else {
            try itemStatement.bindNull(at: 7)
        }
        try itemStatement.bind(item.contentHash, at: 8)
        try itemStatement.bind(item.previewText, at: 9)
        try itemStatement.bind(Int64(item.isPinned ? 1 : 0), at: 10)
        try itemStatement.bind(Int64(item.useCount), at: 11)
        try itemStatement.run()

        for asset in item.assets {
            let assetStatement = try database.prepare(
                """
                INSERT INTO history_assets (
                    id,
                    history_id,
                    item_index,
                    pasteboard_type,
                    storage_kind,
                    data_path,
                    data_blob,
                    byte_count
                ) VALUES (?, ?, ?, ?, 'blob', NULL, ?, ?);
                """
            )
            try assetStatement.bind(UUID().uuidString, at: 1)
            try assetStatement.bind(item.id.uuidString, at: 2)
            try assetStatement.bind(Int64(asset.index), at: 3)
            try assetStatement.bind(asset.pasteboardType.rawValue, at: 4)
            try assetStatement.bind(asset.data, at: 5)
            try assetStatement.bind(Int64(asset.data.count), at: 6)
            try assetStatement.run()
        }
    }

    private func deleteItem(contentHash: String, database: SQLiteDatabase) throws {
        let statement = try database.prepare("DELETE FROM history_items WHERE content_hash = ?;")
        try statement.bind(contentHash, at: 1)
        try statement.run()
    }

    private func pruneHistory(database: SQLiteDatabase) throws {
        let statement = try database.prepare(
            """
            DELETE FROM history_items
            WHERE is_pinned = 0 AND id NOT IN (
                SELECT id FROM history_items
                WHERE is_pinned = 0
                ORDER BY copied_at DESC, id DESC
                LIMIT ?
            );
            """
        )
        try statement.bind(Int64(limit), at: 1)
        try statement.run()
    }

    private func fetchRecentItems(limit requestedLimit: Int, database: SQLiteDatabase) throws -> [ClipboardItem] {
        let statement = try database.prepare(
            """
            SELECT
                id,
                title,
                kind,
                source_app_name,
                source_bundle_identifier,
                copied_at,
                expires_at,
                content_hash,
                preview_text, is_pinned, use_count,
                (SELECT COALESCE(SUM(byte_count), 0) FROM history_assets WHERE history_id = history_items.id)
            FROM history_items
            WHERE is_pinned = 1 OR id IN (
                SELECT id FROM history_items WHERE is_pinned = 0 ORDER BY copied_at DESC, id DESC LIMIT ?
            )
            ORDER BY is_pinned DESC, copied_at DESC, id DESC;
            """
        )
        try statement.bind(Int64(requestedLimit), at: 1)

        var loadedItems: [ClipboardItem] = []
        while try statement.step() {
            guard
                let idText = statement.columnString(at: 0),
                let id = UUID(uuidString: idText),
                let title = statement.columnString(at: 1),
                let kindText = statement.columnString(at: 2),
                let kind = ClipboardKind(rawValue: kindText),
                let contentHash = statement.columnString(at: 7),
                let previewText = statement.columnString(at: 8)
            else {
                continue
            }

            var item = ClipboardItem(
                    id: id,
                    title: title,
                    kind: kind,
                    sourceAppName: statement.columnString(at: 3),
                    sourceBundleIdentifier: statement.columnString(at: 4),
                    copiedAt: Date(timeIntervalSince1970: statement.columnDouble(at: 5)),
                    expiresAt: statement.columnOptionalDouble(at: 6).map(Date.init(timeIntervalSince1970:)),
                    contentHash: contentHash,
                    previewText: previewText,
                    assets: [],
                    hasLoadedAssets: false
                )
            item.isPinned = statement.columnInt64(at: 9) != 0
            item.useCount = Int(statement.columnInt64(at: 10))
            item.storedByteCount = Int(statement.columnInt64(at: 11))
            loadedItems.append(item)
        }
        return loadedItems
    }

    private func fetchAssets(historyID: UUID, database: SQLiteDatabase) throws -> [ClipboardAsset] {
        let statement = try database.prepare(
            """
            SELECT item_index, pasteboard_type, storage_kind, data_blob
            FROM history_assets
            WHERE history_id = ?
            ORDER BY item_index ASC, pasteboard_type ASC;
            """
        )
        try statement.bind(historyID.uuidString, at: 1)

        var assets: [ClipboardAsset] = []
        while try statement.step() {
            guard
                let pasteboardType = statement.columnString(at: 1),
                statement.columnString(at: 2) == "blob"
            else {
                continue
            }

            assets.append(
                ClipboardAsset(
                    index: Int(statement.columnInt64(at: 0)),
                    pasteboardType: NSPasteboard.PasteboardType(pasteboardType),
                    data: statement.columnData(at: 3)
                )
            )
        }
        return assets
    }

}
