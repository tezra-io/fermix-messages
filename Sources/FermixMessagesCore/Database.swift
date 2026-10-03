import Foundation
import SQLite3

/// Where Messages keeps its data. Production derives it from the account's home
/// directory (`getpwuid`, never `$HOME`, which a caller controls); tests inject a
/// synthetic tree.
public struct MessagesLocation {
    public let directory: String
    public let attachmentsRoot: String
    public let stagingRoot: String
    /// What a leading `~` in `attachment.filename` expands to.
    public let tildeHome: String

    public var chatDB: String { directory + "/chat.db" }

    public static func forCurrentUser() -> MessagesLocation {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            preconditionFailure("getpwuid failed for uid \(getuid())")
        }
        let home = String(cString: dir)
        let messages = home + "/Library/Messages"
        return MessagesLocation(directory: messages, attachmentsRoot: messages + "/Attachments",
                                stagingRoot: messages + "/Attachments/Fermix", tildeHome: home)
    }
}

/// Why chat.db could not be used, in the probe's and the data plane's terms.
public enum DBOpenFailure: Error, Equatable {
    case missing
    case permissionDenied(String)
    case unreadable(String)
    case schemaUnexpected([String])

    var helperError: HelperError {
        switch self {
        case .missing: return HelperError(.dbMissing, "chat.db does not exist; Messages has never run here")
        case .permissionDenied(let detail): return .permissionDenied(.fullDiskAccess, "chat.db: \(detail)")
        case .unreadable(let detail): return HelperError(.dbUnreadable, "chat.db: \(detail)")
        case .schemaUnexpected(let missing): return .schemaUnexpected(missing: missing)
        }
    }
}

public struct DirectChat: Equatable {
    public let rowid: Int64
    public let guid: String
}

/// Read-only access to chat.db. Opening verifies every column the row query uses and
/// that `message` can be read; a connection is owned by one thread at a time.
public final class ChatDB {
    /// Every column §7.2's query and the helper's lookups read, by table.
    static let requiredColumns: [(table: String, columns: [String])] = [
        ("message", ["ROWID", "guid", "text", "attributedBody", "date", "is_from_me", "handle_id",
                     "associated_message_type", "associated_message_guid", "thread_originator_guid",
                     "destination_caller_id"]),
        ("handle", ["ROWID", "id", "service"]),
        ("chat", ["ROWID", "guid", "chat_identifier", "service_name", "last_addressed_handle"]),
        ("chat_message_join", ["chat_id", "message_id"]),
        ("message_attachment_join", ["message_id", "attachment_id"]),
        ("attachment", ["ROWID", "guid", "filename", "mime_type", "total_bytes"]),
    ]

    static let rowColumns = """
        m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, m.handle_id,
        m.associated_message_type, m.associated_message_guid, m.thread_originator_guid,
        m.destination_caller_id, h.id, h.service, c.ROWID, c.guid, c.chat_identifier, c.service_name
        """

    static let rowJoins = """
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        """

    let connection: SQLiteConnection

    private init(connection: SQLiteConnection) {
        self.connection = connection
    }

    public static func open(_ location: MessagesLocation) -> Result<ChatDB, DBOpenFailure> {
        var info = stat()
        if stat(location.chatDB, &info) != 0 {
            if errno == ENOENT { return .failure(.missing) }
            return .failure(classify(errno: errno))
        }
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection.openReadOnly(path: location.chatDB)
        } catch let error as SQLiteError {
            return .failure(classify(error))
        } catch {
            return .failure(.unreadable(String(describing: error)))
        }
        if let failure = verify(connection) {
            connection.close()
            return .failure(failure)
        }
        return .success(ChatDB(connection: connection))
    }

    public func close() {
        connection.close()
    }

    /// `{inode, birth_time}` of chat.db; stat needs no read permission, so this works
    /// before Full Disk Access is granted. Nil when the file does not exist.
    static func generation(of path: String) -> DBGeneration? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let born = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
        return DBGeneration(inode: UInt64(info.st_ino), birthTime: Timestamp.format(born))
    }

    private static func verify(_ connection: SQLiteConnection) -> DBOpenFailure? {
        do {
            let missing = try missingColumns(connection)
            if !missing.isEmpty { return .schemaUnexpected(missing) }
            _ = try connection.scalarInt("SELECT 1 FROM message LIMIT 1")
            return nil
        } catch let error as SQLiteError {
            return classify(error)
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    private static func missingColumns(_ connection: SQLiteConnection) throws -> [String] {
        var missing: [String] = []
        for (table, columns) in requiredColumns {
            let present = try connection.query("SELECT name FROM pragma_table_info(?)", [.text(table)]) {
                $0.text(0) ?? ""
            }
            let available = Set(present.isEmpty ? [] : present + ["ROWID"])
            missing += columns.filter { !available.contains($0) }.map { "\(table).\($0)" }
        }
        return missing.sorted()
    }

    private static func classify(_ error: SQLiteError) -> DBOpenFailure {
        error.isPermissionDenied ? .permissionDenied(error.message) : .unreadable(error.description)
    }

    private static func classify(errno code: Int32) -> DBOpenFailure {
        let text = String(cString: strerror(code))
        return code == EPERM || code == EACCES ? .permissionDenied(text) : .unreadable(text)
    }

    // MARK: - Queries

    public func maxRowid() throws -> Int64 {
        try connection.scalarInt("SELECT MAX(ROWID) FROM message") ?? 0
    }

    /// §7.2: rows after `cursor` that are joined to a chat, in ROWID order. A row joined
    /// to two chats appears once, with the lower chat ROWID.
    func rows(after cursor: Int64, limit: Int) throws -> [RawRow] {
        let sql = "SELECT \(Self.rowColumns) \(Self.rowJoins) WHERE m.ROWID > ? ORDER BY m.ROWID, c.ROWID LIMIT ?"
        let rows = try connection.query(sql, [.int(cursor), .int(Int64(limit))], RawRow.init)
        var seen = Set<Int64>()
        return rows.filter { seen.insert($0.rowid).inserted }
    }

    func row(guid: String) throws -> RawRow? {
        let sql = "SELECT \(Self.rowColumns) \(Self.rowJoins) WHERE m.guid = ? ORDER BY c.ROWID LIMIT 1"
        return try connection.query(sql, [.text(guid)], RawRow.init).first
    }

    /// The first message in `(after, through]` with no chat join yet: Messages writes the
    /// join after the message row, so a watcher that wakes in between must wait for it.
    func firstRowWithoutChat(after cursor: Int64, through last: Int64) throws -> Int64? {
        try connection.scalarInt("""
            SELECT m.ROWID FROM message m
            WHERE m.ROWID > ? AND m.ROWID <= ?
              AND NOT EXISTS (SELECT 1 FROM chat_message_join j WHERE j.message_id = m.ROWID)
            ORDER BY m.ROWID LIMIT 1
            """, [.int(cursor), .int(last)])
    }

    func attachments(messageRowid: Int64) throws -> [RawAttachment] {
        let rows = try connection.query("""
            SELECT a.guid, a.filename, a.mime_type, a.total_bytes
            FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id
            WHERE j.message_id = ? ORDER BY a.ROWID
            """, [.int(messageRowid)]) { row in
            (guid: row.text(0) ?? "", filename: row.text(1), mime: row.text(2), bytes: row.int(3))
        }
        return rows.enumerated().map { index, row in
            RawAttachment(index: index, guid: row.guid, filename: row.filename, mime: row.mime, bytes: row.bytes)
        }
    }

    /// §9.4: the account's own aliases, from the handle each chat was last addressed to and
    /// the caller id each message was sent from or received at. Normalized; anything not in
    /// a normalizable form is left out (the own posture then fails closed).
    func selfAliases() throws -> [String] {
        let raw = try connection.query("""
            SELECT value FROM (
              SELECT DISTINCT last_addressed_handle AS value FROM chat
                WHERE last_addressed_handle IS NOT NULL AND last_addressed_handle != ''
              UNION
              SELECT DISTINCT destination_caller_id AS value FROM message
                WHERE destination_caller_id IS NOT NULL AND destination_caller_id != ''
            ) LIMIT 64
            """) { $0.text(0) ?? "" }
        return Set(raw.compactMap { Handles.normalize($0).successValue }).sorted()
    }

    /// §9.4's alias derivation on a fresh connection, for `policy.set` under own_account.
    static func readSelfAliases(_ location: MessagesLocation) -> Result<[String], DBOpenFailure> {
        switch open(location) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let db):
            defer { db.close() }
            do {
                return .success(try db.selfAliases())
            } catch let error as SQLiteError where error.isPermissionDenied {
                return .failure(.permissionDenied(error.message))
            } catch {
                return .failure(.unreadable(String(describing: error)))
            }
        }
    }

    /// The direct iMessage chat for a normalized handle, if Messages has one. SMS chats and
    /// groups are never a send target (R9); no GUID is ever constructed.
    func directChat(handle: String) throws -> DirectChat? {
        try connection.query("""
            SELECT c.ROWID, c.guid FROM chat c
            WHERE c.service_name = 'iMessage' AND instr(c.guid, ';-;') > 0
              AND lower(c.chat_identifier) = lower(?)
            ORDER BY c.ROWID DESC LIMIT 1
            """, [.text(handle)]) { DirectChat(rowid: $0.int(0), guid: $0.text(1) ?? "") }.first
    }
}

extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
