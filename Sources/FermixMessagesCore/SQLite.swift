import Foundation
import SQLite3

/// A small owned wrapper over the SQLite C API: one connection per instance, closed by
/// `close()` or on deinit; every statement is finalized on every path (a `defer` right
/// after `prepare`). A connection is used by one thread at a time; callers serialize.
public enum SQLValue: Equatable {
    case int(Int64)
    case text(String)
    case blob(Data)
    case null
}

public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let systemErrno: Int32
    public let message: String

    /// Apple's SQLite reports a TCC refusal as SQLITE_AUTH ("authorization denied");
    /// a plain file-mode refusal surfaces as SQLITE_PERM/SQLITE_CANTOPEN with EPERM/EACCES.
    public var isPermissionDenied: Bool {
        let primary = code & 0xff
        return primary == SQLITE_AUTH || primary == SQLITE_PERM
            || systemErrno == EPERM || systemErrno == EACCES
    }

    public var description: String { "sqlite \(code) (errno \(systemErrno)): \(message)" }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteConnection {
    private var handle: OpaquePointer?

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { close() }

    /// Opens `path` (a filename, or a `file:` URI when `flags` carries SQLITE_OPEN_URI).
    public static func open(path: String, flags: Int32, busyTimeoutMs: Int32 = 2000) throws -> SQLiteConnection {
        var raw: OpaquePointer?
        let rc = sqlite3_open_v2(path, &raw, flags, nil)
        guard let opened = raw else {
            throw SQLiteError(code: rc, systemErrno: 0, message: "sqlite3_open_v2 returned no handle")
        }
        let connection = SQLiteConnection(handle: opened)
        guard rc == SQLITE_OK else {
            let error = connection.lastError(rc)
            connection.close()
            throw error
        }
        sqlite3_busy_timeout(opened, busyTimeoutMs)
        return connection
    }

    /// `file:<escaped path>?mode=ro` — read-only, never `immutable=1` (that would freeze
    /// the view of a live WAL database).
    public static func openReadOnly(path: String) throws -> SQLiteConnection {
        let uri = "file:" + escapeURIPath(path) + "?mode=ro"
        return try open(path: uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }

    static func escapeURIPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    public func close() {
        guard let open = handle else { return }
        sqlite3_close_v2(open)
        handle = nil
    }

    public var lastInsertRowid: Int64 {
        sqlite3_last_insert_rowid(requireHandle())
    }

    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(requireHandle(), sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard rc == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "sqlite3_exec failed"
            throw SQLiteError(code: rc, systemErrno: sqlite3_system_errno(requireHandle()), message: text)
        }
    }

    /// Runs a statement that returns no rows.
    public func run(_ sql: String, _ binds: [SQLValue] = []) throws {
        _ = try query(sql, binds) { _ in () }
    }

    public func query<T>(_ sql: String, _ binds: [SQLValue] = [], _ map: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { throw lastError(rc) }
            out.append(try map(SQLiteRow(statement: statement)))
        }
    }

    public func scalarInt(_ sql: String, _ binds: [SQLValue] = []) throws -> Int64? {
        try query(sql, binds) { $0.isNull(0) ? nil : $0.int(0) }.first ?? nil
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(requireHandle(), sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let prepared = statement else {
            sqlite3_finalize(statement)
            throw lastError(rc)
        }
        return prepared
    }

    private func bind(_ binds: [SQLValue], to statement: OpaquePointer) throws {
        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let number): rc = sqlite3_bind_int64(statement, index, number)
            case .text(let text): rc = sqlite3_bind_text(statement, index, text, -1, transient)
            case .null: rc = sqlite3_bind_null(statement, index)
            case .blob(let data):
                rc = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
                }
            }
            guard rc == SQLITE_OK else { throw lastError(rc) }
        }
    }

    private func lastError(_ rc: Int32) -> SQLiteError {
        let open = requireHandle()
        return SQLiteError(code: sqlite3_extended_errcode(open) != 0 ? sqlite3_extended_errcode(open) : rc,
                           systemErrno: sqlite3_system_errno(open),
                           message: String(cString: sqlite3_errmsg(open)))
    }

    private func requireHandle() -> OpaquePointer {
        guard let open = handle else { preconditionFailure("SQLite connection used after close") }
        return open
    }
}

/// A view of the current row of a stepping statement; valid only inside the map closure.
public struct SQLiteRow {
    let statement: OpaquePointer

    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    public func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    public func text(_ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    public func blob(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let raw = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: raw, count: count)
    }
}
