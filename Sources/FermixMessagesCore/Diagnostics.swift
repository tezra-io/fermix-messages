import Foundation

/// `rows --home H --since N [--limit K]`: a read-only account of the rows after a
/// cursor, as the admission rule sees them, for the owner asking "why did Fermix not
/// answer?". Handles are redacted the way the log redacts them and no text is printed.
struct RowsReport: Encodable {
    struct Row: Encodable {
        let rowid: Int64
        let isFromMe: Bool
        let direct: Bool
        let sender: String?
        let senderService: String?
        let chat: String?
        let chatService: String?
        let reaction: Bool
        let attachments: Int
        let admitted: Bool
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case rowid, direct, sender, chat, reaction, attachments, admitted, reason
            case isFromMe = "is_from_me"
            case senderService = "sender_service"
            case chatService = "chat_service"
        }
    }

    let since: Int64
    let policy: String
    let rows: [Row]
}

enum Diagnostics {
    static let maxLimit = 200

    static func rows(since: Int64, limit: Int, runtime: Runtime) -> Result<RowsReport, HelperError> {
        let policy: PolicyView?
        switch runtime.policy.get() {
        case .success(let view): policy = view
        case .failure(let error): return .failure(error)
        }
        let db: ChatDB
        switch ChatDB.open(runtime.location) {
        case .success(let opened): db = opened
        case .failure(let failure): return .failure(failure.helperError)
        }
        defer { db.close() }
        do {
            let raws = try db.rows(after: since, limit: min(max(limit, 1), maxLimit))
            let rows = try raws.map { raw -> RowsReport.Row in
                let (admitted, reason) = verdict(raw, policy: policy)
                return RowsReport.Row(
                    rowid: raw.rowid, isFromMe: raw.isFromMe, direct: raw.isDirect,
                    sender: raw.handle.map(Handles.redact), senderService: raw.senderService,
                    chat: raw.chatIdentifier.map(Handles.redact), chatService: raw.chatService,
                    reaction: isReaction(raw), attachments: try db.attachments(messageRowid: raw.rowid).count,
                    admitted: admitted, reason: reason)
            }
            let word = policy.map { "\($0.posture.rawValue) for \(Handles.redact($0.ownerHandle))" } ?? "absent"
            return .success(RowsReport(since: since, policy: word, rows: rows))
        } catch {
            return .failure(HelperError.reading(error))
        }
    }

    private static func isReaction(_ raw: RawRow) -> Bool {
        (2000...2006).contains(raw.associatedType) || (3000...3006).contains(raw.associatedType)
    }

    /// The admission rule of `Feed.admit`, stated as a verdict with its first failing clause.
    private static func verdict(_ raw: RawRow, policy: PolicyView?) -> (Bool, String?) {
        guard let policy else { return (false, "no confirmed policy") }
        guard raw.isDirect else { return (false, "group chat") }
        guard !isReaction(raw) else { return (false, "tapback") }
        let own = policy.posture.rawValue == "own_account"
        if own {
            guard raw.isFromMe else { return (false, "not from this Mac's account under own_account") }
            guard normalized(raw.chatIdentifier) == policy.ownerHandle else { return (false, "chat is not the owner's") }
        } else {
            guard !raw.isFromMe else { return (false, "sent from this Mac's account") }
            guard let sender = normalized(raw.handle), policy.handles.contains(sender) else {
                return (false, "sender is not in the confirmed recipients")
            }
        }
        guard raw.senderService == "iMessage", raw.chatService == "iMessage" else { return (false, "not an iMessage row") }
        return (true, nil)
    }

    private static func normalized(_ handle: String?) -> String? {
        guard let handle, case .success(let value) = Handles.normalize(handle) else { return nil }
        return value
    }
}
