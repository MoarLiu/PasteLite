import Foundation

extension HistoryRepository {
    func migrateOCR(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS recognized_text (
                origin TEXT NOT NULL, item_id TEXT NOT NULL, content_hash TEXT NOT NULL,
                text TEXT NOT NULL, updated_at REAL NOT NULL,
                PRIMARY KEY(origin, item_id)
            );
            CREATE TRIGGER IF NOT EXISTS history_delete_ocr AFTER DELETE ON history_items BEGIN
                DELETE FROM recognized_text WHERE origin = 'history' AND item_id = OLD.id;
            END;
            CREATE TRIGGER IF NOT EXISTS library_delete_ocr AFTER DELETE ON library_items BEGIN
                DELETE FROM recognized_text WHERE origin = 'library' AND item_id = OLD.id;
            END;
            """)
    }

    func ocrSnapshot() -> [String: String] {
        guard let database, let query = try? database.prepare("SELECT origin, item_id, content_hash, text FROM recognized_text;") else { return [:] }
        var values: [String: String] = [:]
        do {
            while try query.step() {
                if let origin = query.columnString(at: 0), let id = query.columnString(at: 1),
                   let hash = query.columnString(at: 2), let text = query.columnString(at: 3) {
                    values["\(origin):\(id):\(hash)"] = text
                }
            }
        } catch { return [:] }
        return values
    }

    func saveRecognizedText(_ text: String, item: ClipboardItem, historyGeneration: Int, savedGeneration: Int) throws -> HistorySnapshot {
        guard item.kind == .image, text.utf8.count <= LibraryValidation.snippetByteLimit,
              historyGeneration >= captureGeneration, savedGeneration >= libraryGeneration else { throw LibraryError.cleared }
        let database = try libraryDatabase()
        let table = item.origin == .history ? "history_items" : "library_items"
        let check = try database.prepare("SELECT content_hash FROM \(table) WHERE id = ?;")
        try check.bind(item.id.uuidString, at: 1)
        guard try check.step(), check.columnString(at: 0) == item.contentHash else { throw LibraryError.changed }
        let query = try database.prepare("INSERT OR REPLACE INTO recognized_text (origin, item_id, content_hash, text, updated_at) VALUES (?, ?, ?, ?, ?);")
        try query.bind(item.origin.rawValue, at: 1); try query.bind(item.id.uuidString, at: 2)
        try query.bind(item.contentHash, at: 3); try query.bind(text, at: 4)
        try query.bind(Date().timeIntervalSince1970, at: 5); try query.run()
        return snapshot()
    }
}
