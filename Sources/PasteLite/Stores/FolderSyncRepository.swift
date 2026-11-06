import Foundation

struct LibrarySyncEvent: Codable, Sendable {
    var format = "PasteLite.Sync"
    var version = 1
    var id = UUID()
    var stamp: String
    var archive: LibraryArchive
    var changedGroups: [UUID]
    var deletedGroups: [UUID]
    var deletedItems: [UUID]
    var deletedSnapshotHashes: [String]? = nil
}

extension HistoryRepository {
    func migrateFolderSync(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS sync_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS sync_versions (entity TEXT NOT NULL, id TEXT NOT NULL, stamp TEXT NOT NULL, PRIMARY KEY(entity,id));
            CREATE TABLE IF NOT EXISTS sync_outbox (id TEXT PRIMARY KEY, event BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS sync_received (id TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS sync_snapshot_deletions (content_hash TEXT PRIMARY KEY, stamp TEXT NOT NULL);
            """)
    }

    func configureFolderSync(enabled: Bool, folder: String? = nil) throws -> HistorySnapshot {
        let database = try libraryDatabase()
        let active = try database.prepare("SELECT value FROM sync_settings WHERE key = 'active';")
        let wasEnabled = try active.step() && active.columnString(at: 0) == "1"
        let location = try database.prepare("SELECT value FROM sync_settings WHERE key = 'folder';")
        let previousFolder = try location.step() ? location.columnString(at: 0) : nil
        let changedFolder = enabled && folder != nil && previousFolder != folder
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let value = try database.prepare("INSERT OR REPLACE INTO sync_settings VALUES ('active', ?);")
            try value.bind(enabled ? "1" : "0", at: 1); try value.run()
            if changedFolder {
                try database.execute("DELETE FROM sync_outbox; DELETE FROM sync_received; DELETE FROM sync_versions; DELETE FROM sync_snapshot_deletions; DELETE FROM sync_settings WHERE key = 'clear_cutoff';")
                let location = try database.prepare("INSERT OR REPLACE INTO sync_settings VALUES ('folder', ?);")
                try location.bind(folder, at: 1); try location.run()
            }
            if !enabled { try database.execute("DELETE FROM sync_outbox;") }
            if enabled && (!wasEnabled || changedFolder) { try recordSyncChanges(previousItems: [], previousGroups: [], database: database) }
            try database.execute("COMMIT;")
        } catch { try? database.execute("ROLLBACK;"); throw error }
        return snapshot()
    }

    func recordSyncChanges(previousItems: [LibraryItem], previousGroups: [LibraryGroup], database: SQLiteDatabase) throws {
        let active = try database.prepare("SELECT value FROM sync_settings WHERE key = 'active';")
        guard try active.step(), active.columnString(at: 0) == "1" else { return }
        let old = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.id, $0) })
        let oldGroups = Dictionary(uniqueKeysWithValues: previousGroups.map { ($0.id, $0) })
        let changed = libraryItems.filter { item in
            guard let previous = old[item.id] else { return true }
            return item.revision != previous.revision || item.name != previous.name || item.content.contentHash != previous.content.contentHash
        }
        let changedGroups = libraryGroups.filter { oldGroups[$0.id]?.name != $0.name }
        let newIDs = Set(libraryItems.map(\.id)), newGroupIDs = Set(libraryGroups.map(\.id))
        let deleted = previousItems.map(\.id).filter { !newIDs.contains($0) }
        let deletedGroups = previousGroups.map(\.id).filter { !newGroupIDs.contains($0) }
        guard !changed.isEmpty || !changedGroups.isEmpty || !deleted.isEmpty || !deletedGroups.isEmpty else { return }
        let clock = try database.prepare("SELECT MAX(stamp) FROM sync_versions;")
        let latest = try clock.step() ? UInt64((clock.columnString(at: 0) ?? "").prefix(20)) ?? 0 : 0
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let stamp = String(format: "%020llu", max(now, latest + 1)) + "-" + UUID().uuidString
        let loaded = try changed.map { entry -> LibraryArchive.Entry in
            var value = entry
            value.content = try resolveLibrary(entry.displayItem)
            value.content.title = entry.content.title
            return .init(value)
        }
        let archive = LibraryArchive(groups: libraryGroups.map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt) }, items: loaded)
        let deletedHashes = previousItems.filter { deleted.contains($0.id) && $0.type == .snapshot }.map { $0.content.contentHash }
        let event = LibrarySyncEvent(stamp: stamp, archive: archive, changedGroups: changedGroups.map(\.id), deletedGroups: deletedGroups, deletedItems: deleted, deletedSnapshotHashes: deletedHashes)
        let data = try JSONEncoder().encode(event)
        guard data.count <= LibraryArchive.maximumBytes else { throw LibraryError.invalid("This sync change exceeds 256 MiB.") }
        let insert = try database.prepare("INSERT INTO sync_outbox VALUES (?, ?);")
        try insert.bind(event.id.uuidString, at: 1); try insert.bind(data, at: 2); try insert.run()
        for id in changed.map(\.id) + deleted { try setSyncVersion("item", id: id, stamp: stamp, database: database) }
        for id in changedGroups.map(\.id) + deletedGroups { try setSyncVersion("group", id: id, stamp: stamp, database: database) }
        for item in previousItems where deleted.contains(item.id) && item.type == .snapshot {
            try recordSnapshotDeletion(item.content.contentHash, stamp: stamp, database: database)
        }
    }

    func syncOutbox() throws -> [(id: UUID, data: Data)] {
        let query = try libraryDatabase().prepare("SELECT id,event FROM sync_outbox ORDER BY id;")
        var result: [(UUID, Data)] = []
        while try query.step() {
            if let id = query.columnString(at: 0).flatMap(UUID.init(uuidString:)) { result.append((id, query.columnData(at: 1))) }
        }
        return result
    }

    func acknowledgeSync(_ id: UUID) throws {
        let query = try libraryDatabase().prepare("DELETE FROM sync_outbox WHERE id = ?;")
        try query.bind(id.uuidString, at: 1); try query.run()
    }

    func hasReceivedSync(_ id: UUID) throws -> Bool {
        let query = try libraryDatabase().prepare("SELECT 1 FROM sync_received WHERE id = ?;")
        try query.bind(id.uuidString, at: 1)
        return try query.step()
    }

    func applySyncEvent(_ event: LibrarySyncEvent, generation: Int) throws -> HistorySnapshot {
        guard generation >= libraryGeneration else { throw LibraryError.cleared }
        guard event.format == "PasteLite.Sync", event.version == 1,
              event.stamp.count == 57, let clock = UInt64(event.stamp.prefix(20)), clock <= 253402300799999999,
              event.stamp.dropFirst(20).first == "-",
              UUID(uuidString: String(event.stamp.suffix(36))) != nil,
              event.deletedItems.count <= 10000, event.deletedGroups.count <= 1000,
              (event.deletedSnapshotHashes?.count ?? 0) <= 10000,
              (event.deletedSnapshotHashes ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw LibraryError.invalid("Invalid sync change.") }
        let incoming = try event.archive.validatedItems()
        let database = try libraryDatabase()
        guard try !hasReceivedSync(event.id) else { return snapshot() }
        let cutoff = try database.prepare("SELECT value FROM sync_settings WHERE key = 'clear_cutoff';")
        if try cutoff.step(), event.stamp <= (cutoff.columnString(at: 0) ?? "") {
            let receipt = try database.prepare("INSERT OR IGNORE INTO sync_received VALUES (?);")
            try receipt.bind(event.id.uuidString, at: 1); try receipt.run()
            return snapshot()
        }
        let previousItems = libraryItems, previousGroups = libraryGroups
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for group in event.archive.groups where event.changedGroups.contains(group.id) || !libraryGroups.contains(where: { $0.id == group.id }) {
                if !event.changedGroups.contains(group.id) {
                    let known = try database.prepare("SELECT 1 FROM sync_versions WHERE entity = 'group' AND id = ?;")
                    try known.bind(group.id.uuidString, at: 1)
                    if try known.step() { continue }
                }
                guard try acceptsSync("group", id: group.id, stamp: event.stamp, database: database) else { continue }
                let name = try LibraryValidation.groupName(group.name, existing: [])
                var resolved = name
                if let collision = libraryGroups.first(where: { $0.id != group.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    if group.id.uuidString < collision.id.uuidString {
                        let displaced = syncConflictName(name, id: collision.id)
                        let rename = try database.prepare("UPDATE library_groups SET name = ?, name_key = ? WHERE id = ?;")
                        try rename.bind(displaced, at: 1); try rename.bind(displaced.lowercased(), at: 2); try rename.bind(collision.id.uuidString, at: 3); try rename.run()
                    } else { resolved = syncConflictName(name, id: group.id) }
                }
                let query = try database.prepare("INSERT INTO library_groups(id,name,name_key,created_at,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,name_key=excluded.name_key,updated_at=excluded.updated_at;")
                try query.bind(group.id.uuidString, at: 1); try query.bind(resolved, at: 2); try query.bind(resolved.lowercased(), at: 3)
                try query.bind(group.createdAt.timeIntervalSince1970, at: 4); try query.bind(Date().timeIntervalSince1970, at: 5); try query.run()
                try setSyncVersion("group", id: group.id, stamp: event.stamp, database: database)
                try refreshLibrary(database)
            }
            for var item in incoming {
                try Task.checkCancellation()
                guard try acceptsSync("item", id: item.id, stamp: event.stamp, database: database) else { continue }
                if item.type == .snapshot {
                    let deletion = try database.prepare("SELECT stamp FROM sync_snapshot_deletions WHERE content_hash = ?;")
                    try deletion.bind(item.content.contentHash, at: 1)
                    if try deletion.step(), (deletion.columnString(at: 0) ?? "") >= event.stamp { continue }
                }
                if let id = item.groupID, !libraryGroups.contains(where: { $0.id == id }) { item.groupID = nil }
                if let duplicate = libraryItems.first(where: { $0.id != item.id && item.type == .snapshot && $0.type == .snapshot && $0.sourceContentHash == item.sourceContentHash }) {
                    // Two offline devices may save the same original under
                    // different UUIDs. Both converge on the smaller UUID.
                    guard item.id.uuidString < duplicate.id.uuidString else { continue }
                    let remove = try database.prepare("DELETE FROM library_items WHERE id = ?;")
                    try remove.bind(duplicate.id.uuidString, at: 1); try remove.run()
                    try setSyncVersion("item", id: duplicate.id, stamp: event.stamp, database: database)
                }
                item.revision = (libraryItems.first { $0.id == item.id }?.revision ?? 0) + 1
                let delete = try database.prepare("DELETE FROM library_items WHERE id = ?;")
                try delete.bind(item.id.uuidString, at: 1); try delete.run()
                try insertLibrary(item, database: database)
                try setSyncVersion("item", id: item.id, stamp: event.stamp, database: database)
                try refreshLibrary(database)
            }
            for hash in event.deletedSnapshotHashes ?? [] {
                try recordSnapshotDeletion(hash, stamp: event.stamp, database: database)
                for item in libraryItems where item.type == .snapshot && item.content.contentHash == hash {
                    guard try acceptsSync("item", id: item.id, stamp: event.stamp, database: database) else { continue }
                    let remove = try database.prepare("DELETE FROM library_items WHERE id = ?;")
                    try remove.bind(item.id.uuidString, at: 1); try remove.run()
                    try setSyncVersion("item", id: item.id, stamp: event.stamp, database: database)
                }
            }
            for id in event.deletedItems {
                guard try acceptsSync("item", id: id, stamp: event.stamp, database: database) else { continue }
                if let item = libraryItems.first(where: { $0.id == id && $0.type == .snapshot }) {
                    try recordSnapshotDeletion(item.content.contentHash, stamp: event.stamp, database: database)
                }
                let query = try database.prepare("DELETE FROM library_items WHERE id = ?;")
                try query.bind(id.uuidString, at: 1); try query.run()
                try setSyncVersion("item", id: id, stamp: event.stamp, database: database)
            }
            for id in event.deletedGroups {
                guard try acceptsSync("group", id: id, stamp: event.stamp, database: database) else { continue }
                let update = try database.prepare("UPDATE library_items SET group_id = NULL, revision = revision + 1 WHERE group_id = ?;")
                try update.bind(id.uuidString, at: 1); try update.run()
                let query = try database.prepare("DELETE FROM library_groups WHERE id = ?;")
                try query.bind(id.uuidString, at: 1); try query.run()
                try setSyncVersion("group", id: id, stamp: event.stamp, database: database)
            }
            let receipt = try database.prepare("INSERT INTO sync_received VALUES (?);")
            try receipt.bind(event.id.uuidString, at: 1); try receipt.run()
            try refreshLibrary(database); try database.execute("COMMIT;")
            return snapshot()
        } catch {
            try? database.execute("ROLLBACK;")
            libraryItems = previousItems; libraryGroups = previousGroups
            throw error
        }
    }

    private func acceptsSync(_ entity: String, id: UUID, stamp: String, database: SQLiteDatabase) throws -> Bool {
        let query = try database.prepare("SELECT stamp FROM sync_versions WHERE entity = ? AND id = ?;")
        try query.bind(entity, at: 1); try query.bind(id.uuidString, at: 2)
        return try !query.step() || (query.columnString(at: 0) ?? "") < stamp
    }

    func setSyncClearCutoff(_ database: SQLiteDatabase) throws {
        let clock = try database.prepare("SELECT MAX(stamp) FROM sync_versions;")
        let latest = try clock.step() ? UInt64((clock.columnString(at: 0) ?? "").prefix(20)) ?? 0 : 0
        let stamp = String(format: "%020llu", max(UInt64(Date().timeIntervalSince1970 * 1_000_000), latest + 1)) + "-" + UUID().uuidString
        let query = try database.prepare("INSERT OR REPLACE INTO sync_settings VALUES ('clear_cutoff', ?);")
        try query.bind(stamp, at: 1); try query.run()
    }

    private func setSyncVersion(_ entity: String, id: UUID, stamp: String, database: SQLiteDatabase) throws {
        let query = try database.prepare("INSERT OR REPLACE INTO sync_versions VALUES (?, ?, ?);")
        try query.bind(entity, at: 1); try query.bind(id.uuidString, at: 2); try query.bind(stamp, at: 3); try query.run()
    }

    private func syncConflictName(_ name: String, id: UUID) -> String {
        // Full UUID avoids secondary collisions from shared eight-character prefixes.
        String(name.prefix(3)) + " " + id.uuidString
    }

    private func recordSnapshotDeletion(_ hash: String, stamp: String, database: SQLiteDatabase) throws {
        let query = try database.prepare("INSERT INTO sync_snapshot_deletions VALUES (?, ?) ON CONFLICT(content_hash) DO UPDATE SET stamp = MAX(stamp, excluded.stamp);")
        try query.bind(hash, at: 1); try query.bind(stamp, at: 2); try query.run()
    }
}
