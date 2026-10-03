import Foundation
import SQLite3

enum LedgerState: String {
    case dispatched, recorded, uncertain, failed
}

/// One send (design §8.2). `watermark` is MAX(message.ROWID) read before AppleScript
/// ran; `chat` is the resolved chat GUID, or "" for a participant send.
struct LedgerRow: Equatable {
    let key: String
    let chat: String
    let to: String
    let textSHA256: String?
    let fileSHA256: String?
    let watermark: Int64
    let state: LedgerState
    let startedAt: Date
    let guid: String?
    let rowid: Int64?
    let finishedAt: Date?
    let failureClass: ErrorKind?
    let detail: String?

    /// What a repeated request with this key is told.
    var outcome: SendResult {
        switch state {
        case .recorded: return .recorded(guid: guid ?? "", rowid: rowid ?? 0)
        case .failed: return .failed(failureClass ?? .sendTimeout)
        case .uncertain, .dispatched:
            return SendResult(disposition: .uncertain, guid: nil, rowid: nil,
                              failureClass: failureClass == .sendTimeout ? .sendTimeout : nil)
        }
    }
}

/// What the watcher knows about an is_from_me row when it asks whether Fermix sent it.
struct EchoProbe {
    let guid: String
    let chatGuid: String
    let chatIdentifier: String?
    let rowid: Int64
    let textSHA256: String?
    /// Hashes of the row's attachment files, computed only when a file send is in flight.
    let attachmentHashes: () -> [String]
}

/// The durable send ledger at FERMIX_HOME/imessage/helper/ledger.sqlite (0600). Every
/// write commits with synchronous=FULL, so a `dispatched` row is on disk before
/// `osascript` runs. One connection, serialized by a lock: the send lane writes, the
/// watcher reads.
final class Ledger {
    static let echoWindow: TimeInterval = 60
    static let retention: TimeInterval = 30 * 86_400
    static let maxRows = 10_000

    static let schema = """
        CREATE TABLE IF NOT EXISTS sends (
          key TEXT PRIMARY KEY NOT NULL,
          chat TEXT NOT NULL,
          "to" TEXT NOT NULL,
          text_sha256 TEXT,
          file_sha256 TEXT,
          watermark_rowid INTEGER NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('dispatched', 'recorded', 'uncertain', 'failed')),
          started_at REAL NOT NULL,
          guid TEXT,
          message_rowid INTEGER,
          finished_at REAL,
          class TEXT,
          detail TEXT
        );
        CREATE INDEX IF NOT EXISTS sends_guid ON sends (guid);
        CREATE INDEX IF NOT EXISTS sends_state ON sends (state, started_at);
        """

    static let columns = """
        key, chat, "to", text_sha256, file_sha256, watermark_rowid, state, started_at, guid, message_rowid,
        finished_at, class, detail
        """

    private let connection: SQLiteConnection
    private let lock = NSLock()
    private var isClosed = false

    private init(connection: SQLiteConnection) {
        self.connection = connection
    }

    static func open(path: String) throws -> Ledger {
        let connection = try SQLiteConnection.open(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        do {
            try connection.execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
            try connection.execute(schema)
        } catch {
            connection.close()
            throw error
        }
        guard chmod(path, 0o600) == 0 else {
            connection.close()
            throw SQLiteError(code: SQLITE_CANTOPEN, systemErrno: errno, message: "chmod 0600 \(path)")
        }
        return Ledger(connection: connection)
    }

    /// Closes the connection once. Every write already committed with synchronous=FULL,
    /// so nothing is lost; a later call on another lane throws instead of touching a
    /// closed handle.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        connection.close()
        isClosed = true
    }

    func find(_ key: String) throws -> LedgerRow? {
        try locked {
            try connection.query("SELECT \(Self.columns) FROM sends WHERE key = ?", [.text(key)], Self.row).first
        }
    }

    func dispatched() throws -> [LedgerRow] {
        try locked {
            try connection.query("SELECT \(Self.columns) FROM sends WHERE state = 'dispatched' ORDER BY started_at",
                                 [], Self.row)
        }
    }

    func insertDispatched(_ row: LedgerRow) throws {
        precondition(row.state == .dispatched, "only a dispatched row is inserted before a send")
        try insert(row)
    }

    func insertFailed(key: String, chat: String, to: String, failure: ErrorKind, detail: String?, at date: Date) throws {
        try insert(LedgerRow(key: key, chat: chat, to: to, textSHA256: nil, fileSHA256: nil, watermark: 0,
                             state: .failed, startedAt: date, guid: nil, rowid: nil, finishedAt: date,
                             failureClass: failure, detail: detail))
    }

    func finish(_ key: String, state: LedgerState, guid: String?, rowid: Int64?, failureClass: ErrorKind?,
                detail: String?, at date: Date) throws {
        precondition(state != .dispatched, "a finished send leaves the dispatched state")
        try locked {
            try connection.run("""
                UPDATE sends SET state = ?, guid = ?, message_rowid = ?, class = ?, detail = ?, finished_at = ?
                WHERE key = ?
                """, [.text(state.rawValue), Self.optional(guid), rowid.map(SQLValue.int) ?? .null,
                      Self.optional(failureClass?.rawValue), Self.optional(detail),
                      .real(date.timeIntervalSince1970), .text(key)])
        }
    }

    /// §9.3: an is_from_me row is Fermix's own when its GUID is a recorded send, or when
    /// a dispatched/uncertain send to that chat started in the last 60 s, below the row,
    /// with the same text or attachment hash.
    func isFermixOwn(_ probe: EchoProbe, now: Date) throws -> Bool {
        let (known, candidates) = try locked { () throws -> (Bool, [(text: String?, file: String?)]) in
            if try connection.scalarInt("SELECT 1 FROM sends WHERE guid = ? LIMIT 1", [.text(probe.guid)]) != nil {
                return (true, [])
            }
            let identifier = probe.chatIdentifier.flatMap { Handles.normalize($0).successValue } ?? ""
            let rows = try connection.query("""
                SELECT text_sha256, file_sha256 FROM sends
                WHERE state IN ('dispatched', 'uncertain') AND (chat = ? OR "to" = ?)
                  AND watermark_rowid < ? AND started_at >= ?
                """, [.text(probe.chatGuid), .text(identifier), .int(probe.rowid),
                      .real(now.timeIntervalSince1970 - Self.echoWindow)]) {
                (text: $0.text(0), file: $0.text(1))
            }
            return (false, rows)
        }
        if known { return true }
        if candidates.contains(where: { $0.text != nil && $0.text == probe.textSHA256 }) { return true }
        let fileHashes = Set(candidates.compactMap(\.file))
        guard !fileHashes.isEmpty else { return false }
        return !fileHashes.isDisjoint(with: probe.attachmentHashes())
    }

    /// Drops finished rows older than 30 days and beyond the newest `maxRows`. A
    /// dispatched row is never pruned: it is reconciled.
    func prune(now: Date, maxRows: Int = Ledger.maxRows) throws {
        try locked {
            try connection.run("DELETE FROM sends WHERE state != 'dispatched' AND started_at < ?",
                               [.real(now.timeIntervalSince1970 - Self.retention)])
            try connection.run("""
                DELETE FROM sends WHERE key IN (
                  SELECT key FROM sends WHERE state != 'dispatched'
                  ORDER BY started_at DESC LIMIT -1 OFFSET ?)
                """, [.int(Int64(maxRows))])
        }
    }

    private func insert(_ row: LedgerRow) throws {
        try locked {
            try connection.run("INSERT INTO sends (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
                .text(row.key), .text(row.chat), .text(row.to), Self.optional(row.textSHA256),
                Self.optional(row.fileSHA256), .int(row.watermark), .text(row.state.rawValue),
                .real(row.startedAt.timeIntervalSince1970), Self.optional(row.guid),
                row.rowid.map(SQLValue.int) ?? .null,
                row.finishedAt.map { SQLValue.real($0.timeIntervalSince1970) } ?? .null,
                Self.optional(row.failureClass?.rawValue), Self.optional(row.detail),
            ])
        }
    }

    private static func row(_ row: SQLiteRow) -> LedgerRow {
        LedgerRow(key: row.text(0) ?? "", chat: row.text(1) ?? "", to: row.text(2) ?? "", textSHA256: row.text(3),
                  fileSHA256: row.text(4), watermark: row.int(5),
                  state: LedgerState(rawValue: row.text(6) ?? "") ?? .uncertain,
                  startedAt: Date(timeIntervalSince1970: row.double(7)), guid: row.text(8),
                  rowid: row.isNull(9) ? nil : row.int(9),
                  finishedAt: row.isNull(10) ? nil : Date(timeIntervalSince1970: row.double(10)),
                  failureClass: row.text(11).flatMap(ErrorKind.init(rawValue:)), detail: row.text(12))
    }

    private static func optional(_ text: String?) -> SQLValue {
        text.map(SQLValue.text) ?? .null
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw SQLiteError(code: SQLITE_MISUSE, systemErrno: 0, message: "ledger closed") }
        return try body()
    }
}
