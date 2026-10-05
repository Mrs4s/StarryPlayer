import Foundation
import SQLite3

enum SQLValue: Sendable, Hashable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .integer(self) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .real(self) } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .integer(self ? 1 : 0) } }
extension Date: SQLBindable { var sqlValue: SQLValue { .real(timeIntervalSince1970) } }
extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

struct SQLiteError: Error, CustomStringConvertible {
    var code: Int32
    var message: String
    var description: String { "SQLite \(code): \(message)" }
}

/// The system's SQLite (`libsqlite3`), thinly: statements are prepared once and kept, values go
/// in and out as `SQLValue`s. Not thread-safe: one owner (the `LibraryStore` actor) uses it.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// `path` nil: in memory (tests).
    init(path: String?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path ?? ":memory:", &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
        try execute("PRAGMA foreign_keys = ON")
        if path != nil {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(error)
            throw SQLiteError(code: status, message: message)
        }
    }

    func run(_ sql: String, _ values: [any SQLBindable] = []) throws {
        try withStatement(sql, values) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error(status) }
        }
    }

    func query<T>(_ sql: String, _ values: [any SQLBindable] = [], _ read: (Row) throws -> T) throws -> [T] {
        try withStatement(sql, values) { statement in
            var rows: [T] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error(status) }
                rows.append(try read(Row(statement: statement)))
            }
            return rows
        }
    }

    /// The first row, read by `read`; nil when there is none.
    func queryFirst<T>(_ sql: String, _ values: [any SQLBindable] = [], _ read: (Row) throws -> T) throws -> T? {
        try withStatement(sql, values) { statement in
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw error(status) }
            return try read(Row(statement: statement))
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? queryFirst("PRAGMA user_version") { $0.int(0) }) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    private var lastMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    private func error(_ status: Int32) -> SQLiteError { SQLiteError(code: status, message: lastMessage) }

    private func withStatement<T>(_ sql: String, _ values: [any SQLBindable], _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            try bind(value.sqlValue, at: Int32(offset + 1), in: statement)
        }
        return try body(statement)
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw error(status) }
        statements[sql] = statement
        return statement
    }

    private func bind(_ value: SQLValue, at index: Int32, in statement: OpaquePointer) throws {
        let status: Int32
        switch value {
        case .integer(let int): status = sqlite3_bind_int64(statement, index, int)
        case .real(let double): status = sqlite3_bind_double(statement, index, double)
        case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, Self.transient)
        case .blob(let data):
            status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
        case .null: status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else { throw error(status) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Row {
        fileprivate let statement: OpaquePointer

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func bool(_ column: Int32) -> Bool { sqlite3_column_int64(statement, column) != 0 }

        func string(_ column: Int32) -> String {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: text)
        }

        func data(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }

        func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
        func optionalInt64(_ column: Int32) -> Int64? { isNull(column) ? nil : int64(column) }
        func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
        func optionalString(_ column: Int32) -> String? { isNull(column) ? nil : string(column) }
        func optionalData(_ column: Int32) -> Data? { isNull(column) ? nil : data(column) }
        func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }
        func optionalDate(_ column: Int32) -> Date? { isNull(column) ? nil : date(column) }
    }
}
