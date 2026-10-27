import Foundation
import SQLite3

/// A connection of its own to an SQLite file, for long work off the main
/// actor: export, import, backup. Used by one task at a time.
final class SQLiteDatabase {
    private var db: OpaquePointer?

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(db)
            db = nil
            throw Failure(message: message)
        }
        // The app writes a line now and then meanwhile.
        sqlite3_busy_timeout(db, 10_000)
    }

    deinit {
        sqlite3_close_v2(db)
    }

    var errorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw Failure(message: message + " [" + sql.prefix(60) + "]")
        }
    }

    /// A statement to step through; finalized by the caller.
    func prepare(_ sql: String, _ arguments: [Any?] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: errorMessage)
        }
        bind(statement, arguments)
        return statement
    }

    func bind(_ statement: OpaquePointer, _ arguments: [Any?]) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case let value as Int64: sqlite3_bind_int64(statement, position, value)
            case let value as Int: sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Bool: sqlite3_bind_int(statement, position, value ? 1 : 0)
            case let value as Double: sqlite3_bind_double(statement, position, value)
            case let value as String:
                sqlite3_bind_text(statement, position, value, -1, SQLiteDatabase.transient)
            case let value as Data:
                _ = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(bytes.count), SQLiteDatabase.transient)
                }
            default: sqlite3_bind_null(statement, position)
            }
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ arguments: [Any?] = []) throws {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        try step(statement)
    }

    /// Steps a prepared statement that returns no rows, after `bind`.
    func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw Failure(message: errorMessage) }
    }

    func query<T>(_ sql: String, _ arguments: [Any?] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Failure(message: errorMessage) }
            rows.append(try row(statement))
        }
        return rows
    }

    /// Calls `body` for each row without keeping them: for whole tables.
    func forEach(_ sql: String, _ arguments: [Any?] = [], body: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Failure(message: errorMessage) }
            try body(statement)
        }
    }

    var changes: Int { Int(sqlite3_changes(db)) }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    static func blob(_ row: OpaquePointer, _ column: Int32) -> Data? {
        sqlite3_column_blob(row, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(row, column))) }
    }

    static func int64(_ row: OpaquePointer, _ column: Int32) -> Int64 {
        sqlite3_column_int64(row, column)
    }

    static func isNull(_ row: OpaquePointer, _ column: Int32) -> Bool {
        sqlite3_column_type(row, column) == SQLITE_NULL
    }

    /// SQLite copies the value: the Swift buffer does not outlive the call.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
