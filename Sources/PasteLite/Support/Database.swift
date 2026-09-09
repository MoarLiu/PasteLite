import Foundation
import SQLite3

enum SQLiteDatabaseError: LocalizedError {
    case openFailed(URL, String)
    case operationFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(url, message):
            return "Could not open SQLite database at \(url.path): \(message)"
        case let .operationFailed(operation, message):
            return "\(operation) failed: \(message)"
        }
    }
}

final class SQLiteDatabase {
    private let url: URL
    private var handle: OpaquePointer?

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteDatabaseError.openFailed(url, message)
        }

        handle = database
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw SQLiteDatabaseError.operationFailed("SQLite execute", message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteDatabaseError.operationFailed("SQLite prepare", lastErrorMessage)
        }
        return SQLiteStatement(statement: statement, database: self)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    fileprivate var lastErrorMessage: String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

final class SQLiteStatement {
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let statement: OpaquePointer
    private unowned let database: SQLiteDatabase

    init(statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ value: String, at index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), Self.transientDestructor)
        }
        try checkBind(result)
    }

    func bind(_ value: String?, at index: Int32) throws {
        guard let value else {
            try bindNull(at: index)
            return
        }
        try bind(value, at: index)
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try checkBind(sqlite3_bind_int64(statement, index, value))
    }

    func bind(_ value: Double, at index: Int32) throws {
        try checkBind(sqlite3_bind_double(statement, index, value))
    }

    func bind(_ value: Data, at index: Int32) throws {
        let result: Int32
        if value.isEmpty {
            result = sqlite3_bind_blob(statement, index, nil, 0, Self.transientDestructor)
        } else {
            result = value.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transientDestructor)
            }
        }
        try checkBind(result)
    }

    func bindNull(at index: Int32) throws {
        try checkBind(sqlite3_bind_null(statement, index))
    }

    func run() throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw SQLiteDatabaseError.operationFailed("SQLite step", database.lastErrorMessage)
        }
    }

    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteDatabaseError.operationFailed("SQLite step", database.lastErrorMessage)
        }
    }

    func columnString(at index: Int32) -> String? {
        guard let rawText = sqlite3_column_text(statement, index) else { return nil }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: rawText, count: byteCount), as: UTF8.self)
    }

    func columnInt64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func columnDouble(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func columnData(at index: Int32) -> Data {
        let byteCount = sqlite3_column_bytes(statement, index)
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: Int(byteCount))
    }

    private func checkBind(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw SQLiteDatabaseError.operationFailed("SQLite bind", database.lastErrorMessage)
        }
    }
}
