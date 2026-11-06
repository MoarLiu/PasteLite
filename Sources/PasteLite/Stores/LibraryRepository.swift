import AppKit
import Foundation

struct LibraryMutation: Sendable {
    var result: HistoryStoreMutationResult
    var itemID: UUID?
    var snapshot: HistorySnapshot
}

private enum LibraryWrite {
    case insert(LibraryItem)
    case replace(LibraryItem)
    case createGroup(UUID, String)
    case renameGroup(UUID, String)
    case deleteGroup(UUID)
    case move(UUID, UUID?)
    case remove(UUID)
    case recordUse(UUID)
    case clear
}

extension HistoryRepository {
    func loadLibrary() -> HistorySnapshot {
        openIfNeeded()
        if let database {
            do { try refreshLibrary(database); libraryErrorMessage = nil }
            catch { libraryErrorMessage = "Could not load saved items. \(error.localizedDescription)" }
        }
        return snapshot()
    }

    func migrateLibrary(_ database: SQLiteDatabase, migratePins: Bool) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS library_groups (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, name_key TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS library_items (
                id TEXT PRIMARY KEY,
                group_id TEXT REFERENCES library_groups(id) ON DELETE SET NULL,
                name TEXT NOT NULL, item_type TEXT NOT NULL, kind TEXT NOT NULL,
                original_title TEXT NOT NULL, preview_text TEXT NOT NULL,
                source_app_name TEXT, source_bundle_identifier TEXT,
                source_history_id TEXT, source_content_hash TEXT,
                content_hash TEXT NOT NULL, saved_at REAL NOT NULL, updated_at REAL NOT NULL,
                last_used_at REAL, use_count INTEGER NOT NULL DEFAULT 0,
                revision INTEGER NOT NULL DEFAULT 1
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_library_snapshot_hash ON library_items(source_content_hash)
                WHERE item_type = 'snapshot';
            CREATE INDEX IF NOT EXISTS idx_library_group ON library_items(group_id);
            CREATE TABLE IF NOT EXISTS library_assets (
                id TEXT PRIMARY KEY,
                library_id TEXT NOT NULL REFERENCES library_items(id) ON DELETE CASCADE,
                item_index INTEGER NOT NULL, pasteboard_type TEXT NOT NULL,
                data_blob BLOB NOT NULL, byte_count INTEGER NOT NULL,
                UNIQUE(library_id, item_index, pasteboard_type)
            );
            CREATE INDEX IF NOT EXISTS idx_library_assets ON library_assets(library_id, item_index, pasteboard_type);
            """)
        guard migratePins else { return }
        let pinned = try database.prepare("""
            SELECT id, title, kind, source_app_name, source_bundle_identifier,
                   copied_at, content_hash, preview_text, use_count
            FROM history_items WHERE is_pinned = 1 AND kind != 'concealed';
            """)
        while try pinned.step() {
            guard let sourceID = pinned.columnString(at: 0), let sourceUUID = UUID(uuidString: sourceID),
                  let title = pinned.columnString(at: 1), let kindText = pinned.columnString(at: 2),
                  let kind = ClipboardKind(rawValue: kindText), let hash = pinned.columnString(at: 6) else { continue }
            let id = UUID()
            var content = ClipboardItem(id: id, title: title, kind: kind,
                                        sourceAppName: pinned.columnString(at: 3),
                                        sourceBundleIdentifier: pinned.columnString(at: 4),
                                        copiedAt: Date(timeIntervalSince1970: pinned.columnDouble(at: 5)),
                                        contentHash: hash, previewText: pinned.columnString(at: 7) ?? "",
                                        assets: try historyAssetsForMigration(sourceUUID, database: database))
            try LibraryValidation.snapshot(content)
            content.origin = .library
            content.useCount = Int(pinned.columnInt64(at: 8))
            let date = content.copiedAt
            try insertLibrary(LibraryItem(id: id, groupID: nil, name: LibraryValidation.defaultName(title),
                                          type: .snapshot, content: content, sourceHistoryID: sourceUUID,
                                          sourceContentHash: hash, savedAt: date, updatedAt: date,
                                          lastUsedAt: nil, revision: 1), database: database)
        }
        try database.execute("UPDATE history_items SET is_pinned = 0 WHERE kind != 'concealed';")
    }

    private func historyAssetsForMigration(_ id: UUID, database: SQLiteDatabase) throws -> [ClipboardAsset] {
        let query = try database.prepare("SELECT item_index, pasteboard_type, data_blob FROM history_assets WHERE history_id = ? AND storage_kind = 'blob' ORDER BY item_index, pasteboard_type;")
        try query.bind(id.uuidString, at: 1)
        var assets: [ClipboardAsset] = []
        while try query.step() {
            guard let type = query.columnString(at: 1) else { continue }
            assets.append(.init(index: Int(query.columnInt64(at: 0)), pasteboardType: .init(type), data: query.columnData(at: 2)))
        }
        return assets
    }

    func refreshLibrary(_ database: SQLiteDatabase) throws {
        let groupQuery = try database.prepare("SELECT id, name, created_at, updated_at FROM library_groups ORDER BY created_at, id;")
        var groups: [LibraryGroup] = []
        while try groupQuery.step() {
            guard let value = groupQuery.columnString(at: 0), let id = UUID(uuidString: value), let name = groupQuery.columnString(at: 1) else { continue }
            groups.append(.init(id: id, name: name, createdAt: Date(timeIntervalSince1970: groupQuery.columnDouble(at: 2)), updatedAt: Date(timeIntervalSince1970: groupQuery.columnDouble(at: 3))))
        }
        let query = try database.prepare("""
            SELECT id, group_id, name, item_type, kind, original_title, preview_text,
                   source_app_name, source_bundle_identifier, source_history_id, source_content_hash,
                   content_hash, saved_at, updated_at, last_used_at, use_count, revision,
                   (SELECT COALESCE(SUM(byte_count), 0) FROM library_assets WHERE library_id = library_items.id)
            FROM library_items ORDER BY name COLLATE NOCASE, id;
            """)
        var loaded: [LibraryItem] = []
        while try query.step() {
            guard let value = query.columnString(at: 0), let id = UUID(uuidString: value),
                  let name = query.columnString(at: 2), let typeText = query.columnString(at: 3),
                  let type = LibraryItemType(rawValue: typeText), let kindText = query.columnString(at: 4),
                  let kind = ClipboardKind(rawValue: kindText), kind != .concealed,
                  let original = query.columnString(at: 5), let preview = query.columnString(at: 6),
                  let hash = query.columnString(at: 11) else { continue }
            let saved = Date(timeIntervalSince1970: query.columnDouble(at: 12))
            var content = ClipboardItem(id: id, title: original, kind: kind,
                                        sourceAppName: query.columnString(at: 7), sourceBundleIdentifier: query.columnString(at: 8),
                                        copiedAt: saved, contentHash: hash, previewText: preview, assets: [], hasLoadedAssets: false)
            content.origin = .library
            content.useCount = Int(query.columnInt64(at: 15))
            content.contentRevision = Int(query.columnInt64(at: 16))
            content.storedByteCount = Int(query.columnInt64(at: 17))
            loaded.append(.init(id: id, groupID: query.columnString(at: 1).flatMap(UUID.init(uuidString:)), name: name,
                                type: type, content: content, sourceHistoryID: query.columnString(at: 9).flatMap(UUID.init(uuidString:)),
                                sourceContentHash: query.columnString(at: 10), savedAt: saved,
                                updatedAt: Date(timeIntervalSince1970: query.columnDouble(at: 13)),
                                lastUsedAt: query.columnOptionalDouble(at: 14).map(Date.init(timeIntervalSince1970:)),
                                revision: content.contentRevision))
        }
        libraryItems = loaded
        libraryGroups = groups
    }

    func saveLibrary(_ draft: LibraryDraft) -> LibraryMutation {
        libraryMutation {
            guard draft.generation >= libraryGeneration else { throw LibraryError.cleared }
            _ = try libraryDatabase()
            let name = try LibraryValidation.name(draft.name)
            try validateGroup(draft.groupID)
            if let id = draft.editingID {
                guard let original = libraryItems.first(where: { $0.id == id }), original.revision == draft.expectedRevision else { throw LibraryError.changed }
                var updated = original
                updated.name = name
                updated.groupID = draft.groupID
                updated.updatedAt = Date()
                updated.revision += 1
                if original.type == .snippet {
                    try LibraryValidation.snippet(draft.body, kind: draft.kind)
                    updated.content.kind = draft.kind
                    updated.content.previewText = draft.body
                    updated.content.assets = [.init(index: 0, pasteboardType: .string, data: Data(draft.body.utf8))]
                    updated.content.hasLoadedAssets = true
                    updated.content.contentHash = ClipboardContentHasher.hash(assets: updated.content.assets)
                } else {
                    let loaded = try resolveLibrary(original.displayItem)
                    updated.content.assets = loaded.assets
                    updated.content.hasLoadedAssets = true
                }
                try libraryTransaction(.replace(updated))
                return id
            }
            let id = UUID()
            let content: ClipboardItem
            if draft.type == .snippet {
                if let source = draft.source { try LibraryValidation.snapshot(source) }
                try LibraryValidation.snippet(draft.body, kind: draft.kind)
                let assets: [ClipboardAsset] = [.init(index: 0, pasteboardType: .string, data: Data(draft.body.utf8))]
                content = ClipboardItem(id: id, title: name, kind: draft.kind, sourceAppName: draft.source?.sourceAppName ?? "PasteLite",
                                        sourceBundleIdentifier: draft.source?.sourceBundleIdentifier,
                                        contentHash: ClipboardContentHasher.hash(assets: assets), previewText: draft.body, assets: assets)
            } else {
                guard let source = draft.source else { throw HistoryItemLoadError.unavailable }
                if let existing = libraryItems.first(where: { $0.type == .snapshot && $0.sourceContentHash == source.contentHash }) { return existing.id }
                let loaded = source.hasLoadedAssets ? source : try resolve(source)
                try LibraryValidation.snapshot(loaded)
                var value = ClipboardItem(id: id, title: loaded.title, kind: loaded.kind, sourceAppName: loaded.sourceAppName,
                                          sourceBundleIdentifier: loaded.sourceBundleIdentifier, contentHash: loaded.contentHash,
                                          previewText: loaded.previewText, assets: loaded.assets)
                value.useCount = loaded.useCount
                content = value
            }
            let now = Date()
            let entry = LibraryItem(id: id, groupID: draft.groupID, name: name, type: draft.type, content: content,
                                    sourceHistoryID: draft.source?.origin == .history ? draft.source?.id : nil,
                                    sourceContentHash: draft.source?.contentHash, savedAt: now, updatedAt: now, lastUsedAt: nil, revision: 1)
            try libraryTransaction(.insert(entry))
            return id
        }
    }

    func createLibraryGroup(name: String, id: UUID = UUID(), generation: Int) -> LibraryMutation {
        libraryMutation {
            guard generation >= libraryGeneration else { throw LibraryError.cleared }
            _ = try libraryDatabase()
            let valid = try LibraryValidation.groupName(name, existing: libraryGroups)
            try libraryTransaction(.createGroup(id, valid))
            return id
        }
    }

    func renameLibraryGroup(id: UUID, name: String) -> LibraryMutation {
        libraryMutation {
            _ = try libraryDatabase()
            guard libraryGroups.contains(where: { $0.id == id }) else { throw LibraryError.changed }
            let valid = try LibraryValidation.groupName(name, existing: libraryGroups, excluding: id)
            try libraryTransaction(.renameGroup(id, valid))
            return id
        }
    }

    func deleteLibraryGroup(id: UUID) -> LibraryMutation {
        libraryMutation {
            try libraryTransaction(.deleteGroup(id))
            return nil
        }
    }

    func moveLibraryItem(id: UUID, groupID: UUID?, generation: Int) -> LibraryMutation {
        libraryMutation {
            guard generation >= libraryGeneration else { throw LibraryError.cleared }
            _ = try libraryDatabase()
            try validateGroup(groupID)
            guard libraryItems.contains(where: { $0.id == id }) else { throw HistoryItemLoadError.unavailable }
            try libraryTransaction(.move(id, groupID))
            return id
        }
    }

    func removeLibraryItem(id: UUID) -> LibraryMutation {
        libraryMutation {
            try libraryTransaction(.remove(id))
            return nil
        }
    }

    func restoreLibrary(_ item: LibraryItem, generation: Int) -> LibraryMutation {
        libraryMutation {
            guard generation >= libraryGeneration else { throw LibraryError.cleared }
            _ = try libraryDatabase()
            if libraryItems.contains(where: { $0.id == item.id || item.type == .snapshot && $0.type == .snapshot && $0.sourceContentHash == item.sourceContentHash }) { return nil }
            var restored = item
            if let group = restored.groupID, !libraryGroups.contains(where: { $0.id == group }) { restored.groupID = nil }
            try LibraryValidation.snapshot(restored.content)
            try libraryTransaction(.insert(restored))
            return restored.id
        }
    }

    func recordLibraryUse(id: UUID) -> LibraryMutation {
        libraryMutation {
            try libraryTransaction(.recordUse(id))
            return id
        }
    }

    func clearLibrary(generation: Int) -> LibraryMutation {
        libraryGeneration = max(libraryGeneration, generation)
        return libraryMutation {
            try libraryTransaction(.clear)
            return nil
        }
    }

    func resolveLibrary(_ item: ClipboardItem) throws -> ClipboardItem {
        let database = try libraryDatabase()
        guard let entry = libraryItems.first(where: { $0.id == item.id }),
              entry.revision == item.contentRevision, entry.content.contentHash == item.contentHash else { throw LibraryError.changed }
        let query = try database.prepare("SELECT item_index, pasteboard_type, data_blob FROM library_assets WHERE library_id = ? ORDER BY item_index, pasteboard_type;")
        try query.bind(item.id.uuidString, at: 1)
        var loaded = entry.displayItem
        var assets: [ClipboardAsset] = []
        while try query.step() {
            guard let type = query.columnString(at: 1) else { continue }
            assets.append(.init(index: Int(query.columnInt64(at: 0)), pasteboardType: .init(type), data: query.columnData(at: 2)))
        }
        guard !assets.isEmpty else { throw HistoryItemLoadError.unavailable }
        loaded.assets = assets
        loaded.hasLoadedAssets = true
        return loaded
    }

    func libraryThumbnail(_ item: ClipboardItem, maxPixelSize: Int) throws -> ClipboardThumbnail? {
        let database = try libraryDatabase()
        guard let entry = libraryItems.first(where: { $0.id == item.id }), entry.revision == item.contentRevision else { throw LibraryError.changed }
        let query = try database.prepare("""
            SELECT data_blob FROM library_assets WHERE library_id = ? AND pasteboard_type IN (?, ?, ?)
            ORDER BY CASE pasteboard_type WHEN ? THEN 0 WHEN ? THEN 1 ELSE 2 END, item_index LIMIT 1;
            """)
        try query.bind(item.id.uuidString, at: 1)
        try query.bind(NSPasteboard.PasteboardType.png.rawValue, at: 2)
        try query.bind(NSPasteboard.PasteboardType.tiff.rawValue, at: 3)
        try query.bind(NSPasteboard.PasteboardType.legacyTIFF.rawValue, at: 4)
        try query.bind(NSPasteboard.PasteboardType.png.rawValue, at: 5)
        try query.bind(NSPasteboard.PasteboardType.tiff.rawValue, at: 6)
        guard try query.step() else { return nil }
        let data = query.columnData(at: 0)
        try Task.checkCancellation()
        return ClipboardImageProcessor.thumbnail(from: data, maxPixelSize: maxPixelSize)
    }

    func libraryDatabase() throws -> SQLiteDatabase {
        openIfNeeded()
        guard let database else { throw LibraryError.unavailable }
        return database
    }

    private func validateGroup(_ id: UUID?) throws {
        if let id, !libraryGroups.contains(where: { $0.id == id }) { throw LibraryError.invalid("This group was removed. Choose another group.") }
    }

    private func libraryMutation(_ body: () throws -> UUID?) -> LibraryMutation {
        do {
            let id = try body()
            libraryErrorMessage = nil
            return LibraryMutation(result: .success, itemID: id, snapshot: snapshot())
        } catch {
            let message = error.localizedDescription
            libraryErrorMessage = message
            return LibraryMutation(result: .failure(message), itemID: nil, snapshot: snapshot())
        }
    }

    private func libraryTransaction(_ operation: LibraryWrite) throws {
        let database = try libraryDatabase()
        let previousItems = libraryItems, previousGroups = libraryGroups
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            // Keep all connection access directly on this actor. In particular,
            // do not pass a closure capturing the connection through a helper.
            switch operation {
            case let .insert(item):
                try insertLibrary(item, database: database)
            case let .replace(item):
                try deleteLibraryRow(item.id, database: database)
                try insertLibrary(item, database: database)
            case let .createGroup(id, name):
                let query = try database.prepare("INSERT INTO library_groups (id, name, name_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?);")
                let now = Date().timeIntervalSince1970
                try query.bind(id.uuidString, at: 1)
                try query.bind(name, at: 2)
                try query.bind(name.lowercased(), at: 3)
                try query.bind(now, at: 4)
                try query.bind(now, at: 5)
                try query.run()
            case let .renameGroup(id, name):
                let query = try database.prepare("UPDATE library_groups SET name = ?, name_key = ?, updated_at = ? WHERE id = ?;")
                try query.bind(name, at: 1)
                try query.bind(name.lowercased(), at: 2)
                try query.bind(Date().timeIntervalSince1970, at: 3)
                try query.bind(id.uuidString, at: 4)
                try query.run()
            case let .deleteGroup(id):
                let items = try database.prepare("UPDATE library_items SET group_id = NULL, revision = revision + 1 WHERE group_id = ?;")
                try items.bind(id.uuidString, at: 1)
                try items.run()
                let query = try database.prepare("DELETE FROM library_groups WHERE id = ?;")
                try query.bind(id.uuidString, at: 1)
                try query.run()
            case let .move(id, groupID):
                let query = try database.prepare("UPDATE library_items SET group_id = ?, updated_at = ?, revision = revision + 1 WHERE id = ?;")
                try query.bind(groupID?.uuidString, at: 1)
                try query.bind(Date().timeIntervalSince1970, at: 2)
                try query.bind(id.uuidString, at: 3)
                try query.run()
            case let .remove(id):
                try deleteLibraryRow(id, database: database)
            case let .recordUse(id):
                let query = try database.prepare("UPDATE library_items SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?;")
                try query.bind(Date().timeIntervalSince1970, at: 1)
                try query.bind(id.uuidString, at: 2)
                try query.run()
            case .clear:
                try database.execute("DELETE FROM library_items; DELETE FROM library_groups; DELETE FROM sync_outbox;")
                try setSyncClearCutoff(database)
            }
            // Read the new state before commit so a failed refresh also rolls back.
            try refreshLibrary(database)
            try recordSyncChanges(previousItems: previousItems, previousGroups: previousGroups, database: database)
            try database.execute("COMMIT;")
        } catch {
            libraryItems = previousItems
            libraryGroups = previousGroups
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private func deleteLibraryRow(_ id: UUID, database: SQLiteDatabase) throws {
        let query = try database.prepare("DELETE FROM library_items WHERE id = ?;")
        try query.bind(id.uuidString, at: 1); try query.run()
    }

    func insertLibrary(_ item: LibraryItem, database: SQLiteDatabase) throws {
        let query = try database.prepare("""
            INSERT INTO library_items (id, group_id, name, item_type, kind, original_title, preview_text,
              source_app_name, source_bundle_identifier, source_history_id, source_content_hash, content_hash,
              saved_at, updated_at, last_used_at, use_count, revision)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        try query.bind(item.id.uuidString, at: 1); try query.bind(item.groupID?.uuidString, at: 2)
        try query.bind(item.name, at: 3); try query.bind(item.type.rawValue, at: 4)
        try query.bind(item.content.kind.rawValue, at: 5); try query.bind(item.content.title, at: 6)
        try query.bind(item.content.previewText, at: 7); try query.bind(item.content.sourceAppName, at: 8)
        try query.bind(item.content.sourceBundleIdentifier, at: 9); try query.bind(item.sourceHistoryID?.uuidString, at: 10)
        try query.bind(item.sourceContentHash, at: 11); try query.bind(item.content.contentHash, at: 12)
        try query.bind(item.savedAt.timeIntervalSince1970, at: 13); try query.bind(item.updatedAt.timeIntervalSince1970, at: 14)
        if let date = item.lastUsedAt { try query.bind(date.timeIntervalSince1970, at: 15) } else { try query.bindNull(at: 15) }
        try query.bind(Int64(item.content.useCount), at: 16); try query.bind(Int64(item.revision), at: 17); try query.run()
        for asset in item.content.assets {
            let value = try database.prepare("INSERT INTO library_assets (id, library_id, item_index, pasteboard_type, data_blob, byte_count) VALUES (?, ?, ?, ?, ?, ?);")
            try value.bind(UUID().uuidString, at: 1); try value.bind(item.id.uuidString, at: 2)
            try value.bind(Int64(asset.index), at: 3); try value.bind(asset.pasteboardType.rawValue, at: 4)
            try value.bind(asset.data, at: 5); try value.bind(Int64(asset.data.count), at: 6); try value.run()
        }
    }

    func exportLibrary(to url: URL) throws {
        _ = try libraryDatabase()
        let loaded = try libraryItems.map { item -> LibraryItem in
            var value = item
            value.content = try resolveLibrary(item.displayItem)
            value.content.title = item.content.title
            return value
        }
        let archive = LibraryArchive(groups: libraryGroups.map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt) },
                                     items: loaded.map(LibraryArchive.Entry.init))
        try archive.write(to: url)
    }

    func importLibrary(_ archive: LibraryArchive, generation: Int) throws -> LibraryImportResult {
        let incoming = try archive.validatedItems()
        guard generation >= libraryGeneration else { throw LibraryError.cleared }
        let database = try libraryDatabase()
        let originalItems = libraryItems, originalGroups = libraryGroups
        var mapping: [UUID: UUID] = [:]
        var added = 0, skipped = 0
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for group in archive.groups {
                let normalizedName = try LibraryValidation.groupName(group.name, existing: [])
                if let existing = libraryGroups.first(where: { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame }) {
                    mapping[group.id] = existing.id
                    continue
                }
                let id = libraryGroups.contains(where: { $0.id == group.id }) ? UUID() : group.id
                let name = try LibraryValidation.groupName(normalizedName, existing: libraryGroups)
                let query = try database.prepare("INSERT INTO library_groups (id, name, name_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?);")
                try query.bind(id.uuidString, at: 1); try query.bind(name, at: 2); try query.bind(name.lowercased(), at: 3)
                try query.bind(group.createdAt.timeIntervalSince1970, at: 4); try query.bind(group.createdAt.timeIntervalSince1970, at: 5)
                try query.run()
                libraryGroups.append(.init(id: id, name: name, createdAt: group.createdAt, updatedAt: group.createdAt))
                mapping[group.id] = id
            }
            for var item in incoming {
                try Task.checkCancellation()
                // Preserve existing names, groups, and edits. Conflicting UUIDs
                // are skipped rather than silently replacing user content.
                if libraryItems.contains(where: { $0.id == item.id || item.type == .snapshot && $0.type == .snapshot && $0.sourceContentHash == item.sourceContentHash }) {
                    skipped += 1; continue
                }
                item.groupID = item.groupID.flatMap { mapping[$0] }
                try insertLibrary(item, database: database)
                libraryItems.append(item.metadataOnly)
                added += 1
            }
            try refreshLibrary(database)
            try recordSyncChanges(previousItems: originalItems, previousGroups: originalGroups, database: database)
            try database.execute("COMMIT;")
            return LibraryImportResult(added: added, skipped: skipped, snapshot: snapshot())
        } catch {
            try? database.execute("ROLLBACK;")
            libraryItems = originalItems; libraryGroups = originalGroups
            throw error
        }
    }
}
