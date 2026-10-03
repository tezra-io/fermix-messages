import Foundation
@testable import FermixMessagesCore

/// A synthetic `~/Library/Messages` with a `chat.db` built from the real schema's DDL for
/// every table and column the helper reads (plus a few neighbours, so the schema is not
/// trivially minimal). The writer connection stays open in WAL mode for the fixture's
/// life, the way Messages holds the live database.
final class ChatDBFixture {
    static let ddl = """
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, id TEXT NOT NULL, country TEXT,
        service TEXT NOT NULL, uncanonicalized_id TEXT, person_centric_id TEXT, UNIQUE (id, service));
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER,
        state INTEGER, account_id TEXT, properties BLOB, chat_identifier TEXT, service_name TEXT,
        room_name TEXT, account_login TEXT, is_archived INTEGER DEFAULT 0, last_addressed_handle TEXT,
        display_name TEXT, group_id TEXT, is_filtered INTEGER DEFAULT 0, successful_query INTEGER);
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT,
        replace INTEGER DEFAULT 0, service_center TEXT, handle_id INTEGER DEFAULT 0, subject TEXT,
        country TEXT, attributedBody BLOB, version INTEGER DEFAULT 0, type INTEGER DEFAULT 0, service TEXT,
        account TEXT, account_guid TEXT, error INTEGER DEFAULT 0, date INTEGER, date_read INTEGER,
        date_delivered INTEGER, is_delivered INTEGER DEFAULT 0, is_finished INTEGER DEFAULT 0,
        is_from_me INTEGER DEFAULT 0, is_empty INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0,
        associated_message_guid TEXT DEFAULT NULL, associated_message_type INTEGER DEFAULT 0,
        thread_originator_guid TEXT, thread_originator_part TEXT, destination_caller_id TEXT);
    CREATE TABLE chat_message_join (chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
        message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE, message_date INTEGER DEFAULT 0,
        PRIMARY KEY (chat_id, message_id));
    CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
        created_date INTEGER DEFAULT 0, start_date INTEGER DEFAULT 0, filename TEXT, uti TEXT,
        mime_type TEXT, transfer_state INTEGER DEFAULT 0, is_outgoing INTEGER DEFAULT 0, user_info BLOB,
        transfer_name TEXT, total_bytes INTEGER DEFAULT 0);
    CREATE TABLE message_attachment_join (message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
        attachment_id INTEGER REFERENCES attachment (ROWID) ON DELETE CASCADE, UNIQUE(message_id, attachment_id));
    """

    /// 2026-10-03T12:00:00Z as Messages stores it: nanoseconds since 2001-01-01 UTC.
    static let noon: Int64 = ChatDBFixture.appleNanoseconds(Date(timeIntervalSince1970: 1_791_028_800))

    static func appleNanoseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
    }

    let directory = TestDirectory()
    let location: MessagesLocation
    private(set) var writer: SQLiteConnection
    private var guidCounter = 0

    init(ddl: String = ChatDBFixture.ddl) {
        let messages = directory.sub("Library/Messages")
        let attachments = directory.sub("Library/Messages/Attachments")
        location = MessagesLocation(directory: messages, attachmentsRoot: attachments,
                                    stagingRoot: attachments + "/Fermix", tildeHome: directory.path)
        writer = Self.openWriter(location.chatDB)
        must { try writer.execute("PRAGMA journal_mode=WAL") }
        must { try writer.execute(ddl) }
    }

    static func openWriter(_ path: String) -> SQLiteConnection {
        do {
            return try SQLiteConnection.open(path: path, flags: SQLITE_OPEN_READWRITE_CREATE)
        } catch {
            preconditionFailure("fixture writer: \(error)")
        }
    }

    /// Replaces chat.db with a fresh file (a new inode): what a Messages reset does.
    func replaceDatabase(seedRowid: Int64) {
        writer.close()
        for suffix in ["", "-wal", "-shm"] {
            _ = unlink(location.chatDB + suffix)
        }
        writer = Self.openWriter(location.chatDB)
        must { try writer.execute("PRAGMA journal_mode=WAL") }
        must { try writer.execute(Self.ddl) }
        must { try writer.run("INSERT INTO sqlite_sequence (name, seq) VALUES ('message', ?)", [.int(seedRowid)]) }
    }

    func nextGuid(_ prefix: String) -> String {
        guidCounter += 1
        return "\(prefix)-\(guidCounter)"
    }

    @discardableResult
    func handle(_ id: String, service: String = "iMessage") -> Int64 {
        must { try writer.run("INSERT INTO handle (id, service) VALUES (?, ?)", [.text(id), .text(service)]) }
        return writer.lastInsertRowid
    }

    @discardableResult
    func chat(_ identifier: String, service: String = "iMessage", group: Bool = false,
              lastAddressed: String? = nil, guid: String? = nil) -> Int64 {
        let chatGuid = guid ?? "any;\(group ? "+" : "-");\(identifier)"
        must {
            try writer.run("""
                INSERT INTO chat (guid, chat_identifier, service_name, last_addressed_handle, style)
                VALUES (?, ?, ?, ?, ?)
                """, [.text(chatGuid), .text(identifier), .text(service),
                      lastAddressed.map(SQLValue.text) ?? .null, .int(group ? 43 : 45)])
        }
        return writer.lastInsertRowid
    }

    struct MessageSpec {
        var text: String? = "hello"
        var body: Data?
        var date: Int64 = ChatDBFixture.noon
        var fromMe = false
        var handle: Int64 = 0
        var chat: Int64?
        var associatedType: Int64 = 0
        var associatedGuid: String?
        var thread: String?
        var destination: String?
        var guid: String?
    }

    @discardableResult
    func message(_ spec: MessageSpec) -> (rowid: Int64, guid: String) {
        let guid = spec.guid ?? nextGuid("MSG")
        must {
            try writer.run("""
                INSERT INTO message (guid, text, attributedBody, date, is_from_me, handle_id,
                    associated_message_type, associated_message_guid, thread_originator_guid,
                    destination_caller_id, service)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'iMessage')
                """, [.text(guid), spec.text.map(SQLValue.text) ?? .null, spec.body.map(SQLValue.blob) ?? .null,
                      .int(spec.date), .int(spec.fromMe ? 1 : 0), .int(spec.handle), .int(spec.associatedType),
                      spec.associatedGuid.map(SQLValue.text) ?? .null, spec.thread.map(SQLValue.text) ?? .null,
                      spec.destination.map(SQLValue.text) ?? .null])
        }
        let rowid = writer.lastInsertRowid
        if let chat = spec.chat { join(chat: chat, message: rowid) }
        return (rowid, guid)
    }

    func join(chat: Int64, message: Int64) {
        must {
            try writer.run("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)",
                           [.int(chat), .int(message)])
        }
    }

    @discardableResult
    func attachment(message: Int64, filename: String?, mime: String?, bytes: Int64) -> String {
        let guid = nextGuid("AT")
        must {
            try writer.run("INSERT INTO attachment (guid, filename, mime_type, total_bytes) VALUES (?, ?, ?, ?)",
                           [.text(guid), filename.map(SQLValue.text) ?? .null, mime.map(SQLValue.text) ?? .null,
                            .int(bytes)])
        }
        let attachment = writer.lastInsertRowid
        must {
            try writer.run("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)",
                           [.int(message), .int(attachment)])
        }
        return guid
    }

    func openReader() -> ChatDB {
        switch ChatDB.open(location) {
        case .success(let db): return db
        case .failure(let failure): preconditionFailure("fixture reader: \(failure)")
        }
    }

    private func must(_ body: () throws -> Void) {
        do { try body() } catch { preconditionFailure("fixture: \(error)") }
    }
}

let SQLITE_OPEN_READWRITE_CREATE: Int32 = 0x0000_0002 | 0x0000_0004
