import Foundation

/// A bounded record of the message GUIDs this process put on the wire. `attachment.fetch`
/// serves only these (§8.3, R10).
final class EmittedRegistry {
    private let capacity: Int
    private let lock = NSLock()
    private var members = Set<String>()
    private var order: [String] = []

    init(capacity: Int = 10_000) {
        self.capacity = capacity
    }

    func insert(_ guid: String) {
        lock.lock()
        defer { lock.unlock() }
        guard members.insert(guid).inserted else { return }
        order.append(guid)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
    }

    func contains(_ guid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return members.contains(guid)
    }
}

extension RawRow {
    /// A direct chat by its GUID's shape (`;-;`); a group is `;+;`. The prefix (iMessage,
    /// SMS, any) is never read (R9).
    var isDirect: Bool { chatGuid.contains(";-;") && !chatGuid.contains(";+;") }
}

extension HelperError {
    /// A read that failed after the database opened.
    static func reading(_ error: Error) -> HelperError {
        if let sqlite = error as? SQLiteError, sqlite.isPermissionDenied {
            return .permissionDenied(.fullDiskAccess, "chat.db: \(sqlite.message)")
        }
        return HelperError(.dbUnreadable, "chat.db: \(error)")
    }
}

/// The privacy boundary (§7.4, §9.2) and the rows that cross it. Only rows of direct
/// chats, iMessage on both the handle and the chat, from the confirmed counterpart
/// (dedicated_account) or the owner's own self chat (own_account), and not one of
/// Fermix's own sends, ever leave the helper. Reactions pass under the same rule.
final class Feed {
    static let attachmentHashCap: Int64 = 100 * 1024 * 1024
    static let smsLogCapacity = 1000

    let location: MessagesLocation
    let policy: PolicyService
    let emitted: EmittedRegistry
    private let ledger: Ledger
    private let log: Logger
    let now: () -> Date
    private let onOwnerIsThisMac: (PolicyStateEvent) -> Void
    private let lock = NSLock()
    private var smsLogged = Set<String>()

    init(location: MessagesLocation, policy: PolicyService, ledger: Ledger, emitted: EmittedRegistry, log: Logger,
         now: @escaping () -> Date, onOwnerIsThisMac: @escaping (PolicyStateEvent) -> Void) {
        self.location = location
        self.policy = policy
        self.ledger = ledger
        self.emitted = emitted
        self.log = log
        self.now = now
        self.onOwnerIsThisMac = onOwnerIsThisMac
    }

    /// The data-plane gate: a readable chat.db and a confirmed policy.
    func open() -> Result<(ChatDB, StoredPolicy), HelperError> {
        switch ChatDB.open(location) {
        case .failure(let failure):
            return .failure(failure.helperError)
        case .success(let db):
            switch policy.requireConfirmed() {
            case .success(let stored): return .success((db, stored))
            case .failure(let error):
                db.close()
                return .failure(error)
            }
        }
    }

    /// `messages.after` (§7.3 overflow recovery): admitted rows after `since_rowid`, at most
    /// `limit`, never bounded by age; the scan is bounded by MAX(ROWID) when it began.
    func after(_ params: MessagesAfterParams) -> Result<MessagesAfterResult, HelperError> {
        let db: ChatDB
        let stored: StoredPolicy
        switch open() {
        case .success(let opened): (db, stored) = opened
        case .failure(let error): return .failure(error)
        }
        defer { db.close() }
        do {
            let max = try db.maxRowid()
            var cursor = params.sinceRowid
            var messages: [MessageEvent] = []
            while cursor < max && messages.count < params.limit {
                let rows = try db.rows(after: cursor, limit: 256)
                guard !rows.isEmpty else { break }
                for raw in rows where messages.count < params.limit {
                    cursor = raw.rowid
                    if let admitted = try admit(raw, policy: stored, db: db) { messages.append(emit(admitted)) }
                }
            }
            return .success(MessagesAfterResult(messages: messages, hasMore: messages.count == params.limit && cursor < max))
        } catch {
            return .failure(.reading(error))
        }
    }

    /// The decoded row when it may leave the helper under `policy`, else nil.
    func admit(_ raw: RawRow, policy: StoredPolicy, db: ChatDB) throws -> DecodedRow? {
        guard raw.isDirect, try !ownersSelfChat(raw, policy, db: db), postureAdmits(raw, policy) else { return nil }
        guard raw.senderService == "iMessage", raw.chatService == "iMessage" else {
            noteSms(raw)
            return nil
        }
        let decoded = DecodedRow(raw, attachments: try db.attachments(messageRowid: raw.rowid), now: now())
        if decoded.dateClamped { log.event("date_clamped", ["rowid": String(raw.rowid)]) }
        if raw.isFromMe, try ledger.isFermixOwn(echoProbe(decoded), now: now()) {
            return nil
        }
        return decoded
    }

    /// The event for an admitted row, recorded as emitted.
    func emit(_ row: DecodedRow) -> MessageEvent {
        emitted.insert(row.raw.guid)
        return row.event
    }

    /// §9, the fresh-account case the derivation at `policy.set` could not see: under a
    /// dedicated policy, an is_from_me row in the owner's direct chat that Fermix did not
    /// send means Messages here is signed in as the owner. Never admitted; reported once.
    private func ownersSelfChat(_ raw: RawRow, _ policy: StoredPolicy, db: ChatDB) throws -> Bool {
        guard policy.posture == .dedicatedAccount, raw.isFromMe,
              raw.chatIdentifier.flatMap({ Handles.normalize($0).successValue }) == policy.ownerHandle else {
            return false
        }
        let decoded = DecodedRow(raw, attachments: try db.attachments(messageRowid: raw.rowid), now: now())
        guard try !ledger.isFermixOwn(echoProbe(decoded), now: now()) else { return false }
        if self.policy.noteOwnerIsThisMac(policy) {
            let owner = Handles.redact(policy.ownerHandle)
            log.event("owner_is_this_mac", ["owner": owner, "rowid": String(raw.rowid)])
            onOwnerIsThisMac(PolicyStateEvent(state: .ownerIsThisMac, owner: owner))
        }
        return true
    }

    private func postureAdmits(_ raw: RawRow, _ policy: StoredPolicy) -> Bool {
        switch policy.posture {
        case .dedicatedAccount:
            guard !raw.isFromMe, let sender = raw.handle.flatMap({ Handles.normalize($0).successValue }) else {
                return false
            }
            return policy.allowed.contains(sender)
        case .ownAccount:
            let chat = raw.chatIdentifier.flatMap { Handles.normalize($0).successValue }
            return raw.isFromMe && chat == policy.ownerHandle
        }
    }

    /// One log line per sender whose rows are refused for not being iMessage.
    private func noteSms(_ raw: RawRow) {
        let sender = Handles.redact(raw.handle ?? raw.chatIdentifier ?? "")
        lock.lock()
        let first = smsLogged.count < Self.smsLogCapacity && smsLogged.insert(sender).inserted
        lock.unlock()
        if first { log.event("sms_not_supported", ["sender": sender]) }
    }

    private func echoProbe(_ row: DecodedRow) -> EchoProbe {
        let attachments = row.attachments
        let location = location
        return EchoProbe(guid: row.raw.guid, chatGuid: row.raw.chatGuid, chatIdentifier: row.raw.chatIdentifier,
                         rowid: row.raw.rowid, textSHA256: row.text.map(FileCopy.sha256)) {
            attachments.compactMap { attachment in
                guard let source = Attachments.sourcePath(attachment.filename, location: location),
                      case .success(let real) = SafePath.resolve(source, under: location.attachmentsRoot) else {
                    return nil
                }
                return FileCopy.sha256(file: real, cap: Self.attachmentHashCap)
            }
        }
    }
}
