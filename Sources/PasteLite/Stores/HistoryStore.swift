import AppKit
import Foundation
import os

enum HistoryStoreMutationResult: Equatable {
    case success
    case failure(String)

    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}

@MainActor
protocol HistoryStore: AnyObject, ObservableObject {
    var items: [ClipboardItem] { get }
    func loadRecentItems(limit: Int)
    @discardableResult func add(_ item: ClipboardItem) -> HistoryStoreMutationResult
    @discardableResult func remove(id: ClipboardItem.ID) -> HistoryStoreMutationResult
    @discardableResult func clear() -> HistoryStoreMutationResult
}

@MainActor
extension HistoryStore {
    func loadRecentItems() {
        loadRecentItems(limit: SQLiteHistoryStore.defaultLimit)
    }
}

@MainActor
final class SQLiteHistoryStore: HistoryStore {
    nonisolated static let defaultLimit = 500
    private static let logger = Logger(subsystem: "com.xia.PasteLite", category: "history-store")

    @Published private(set) var items: [ClipboardItem] = []
    private let limit: Int
    private let database: SQLiteDatabase?

    init(databaseURL: URL = PasteLiteDatabasePaths.historyDatabaseURL, limit: Int = SQLiteHistoryStore.defaultLimit) {
        self.limit = limit

        let openedDatabase: SQLiteDatabase?
        do {
            let database = try SQLiteDatabase(url: databaseURL)
            try Self.migrate(database)
            openedDatabase = database
        } catch {
            openedDatabase = nil
            Self.logger.warning("PasteLite history store is using memory only: \(error.localizedDescription, privacy: .public)")
        }

        self.database = openedDatabase
        loadRecentItems(limit: limit)
    }

    func loadRecentItems(limit requestedLimit: Int) {
        guard let database else { return }
        do {
            items = try fetchRecentItems(limit: requestedLimit, database: database)
        } catch {
            Self.logger.error("PasteLite could not load clipboard history: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func add(_ item: ClipboardItem) -> HistoryStoreMutationResult {
        guard let database else {
            addInMemory(item)
            return .success
        }

        do {
            try database.transaction {
                try deleteItem(contentHash: item.contentHash, database: database)
                try insert(item, database: database)
                try pruneHistory(database: database)
            }
            addInMemory(item)
            return .success
        } catch {
            Self.logger.error("PasteLite could not persist clipboard item: \(error.localizedDescription, privacy: .public)")
            return .failure("Could not save this clipboard item to history.")
        }
    }

    @discardableResult
    func remove(id: ClipboardItem.ID) -> HistoryStoreMutationResult {
        guard let database else {
            items.removeAll { $0.id == id }
            return .success
        }

        do {
            let statement = try database.prepare("DELETE FROM history_items WHERE id = ?;")
            try statement.bind(id.uuidString, at: 1)
            try statement.run()
            items.removeAll { $0.id == id }
            return .success
        } catch {
            Self.logger.error("PasteLite could not remove clipboard item: \(error.localizedDescription, privacy: .public)")
            return .failure("Could not remove this clipboard item from history.")
        }
    }

    @discardableResult
    func clear() -> HistoryStoreMutationResult {
        guard let database else {
            items.removeAll()
            return .success
        }

        do {
            try database.execute("DELETE FROM history_items;")
            items.removeAll()
            return .success
        } catch {
            Self.logger.error("PasteLite could not clear clipboard history: \(error.localizedDescription, privacy: .public)")
            return .failure("Could not clear clipboard history.")
        }
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS history_items (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                kind TEXT NOT NULL,
                source_app_name TEXT,
                source_bundle_identifier TEXT,
                copied_at REAL NOT NULL,
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

            PRAGMA user_version = 1;
            """
        )
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
                content_hash,
                preview_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try itemStatement.bind(item.id.uuidString, at: 1)
        try itemStatement.bind(item.title, at: 2)
        try itemStatement.bind(item.kind.rawValue, at: 3)
        try itemStatement.bind(item.sourceAppName, at: 4)
        try itemStatement.bind(item.sourceBundleIdentifier, at: 5)
        try itemStatement.bind(item.copiedAt.timeIntervalSince1970, at: 6)
        try itemStatement.bind(item.contentHash, at: 7)
        try itemStatement.bind(item.previewText, at: 8)
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
            WHERE id NOT IN (
                SELECT id FROM history_items
                ORDER BY copied_at DESC
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
                content_hash,
                preview_text
            FROM history_items
            ORDER BY copied_at DESC
            LIMIT ?;
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
                let contentHash = statement.columnString(at: 6),
                let previewText = statement.columnString(at: 7)
            else {
                continue
            }

            let assets = try fetchAssets(historyID: id, database: database)
            loadedItems.append(
                ClipboardItem(
                    id: id,
                    title: title,
                    kind: kind,
                    sourceAppName: statement.columnString(at: 3),
                    sourceBundleIdentifier: statement.columnString(at: 4),
                    copiedAt: Date(timeIntervalSince1970: statement.columnDouble(at: 5)),
                    contentHash: contentHash,
                    previewText: previewText,
                    assets: assets
                )
            )
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

    private func addInMemory(_ item: ClipboardItem) {
        items.removeAll { $0.contentHash == item.contentHash }
        items.insert(item, at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
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
