import Foundation

/// One row of §7.2's query, as read.
struct RawRow: Equatable {
    let rowid: Int64
    let guid: String
    let text: String?
    let attributedBody: Data?
    let date: Int64
    let isFromMe: Bool
    let handleId: Int64
    let associatedType: Int64
    let associatedGuid: String?
    let threadOriginatorGuid: String?
    let destinationCallerId: String?
    let handle: String?
    let handleService: String?
    let chatRowid: Int64
    let chatGuid: String
    let chatIdentifier: String?
    let chatService: String?
}

extension RawRow {
    init(_ row: SQLiteRow) {
        self.init(rowid: row.int(0), guid: row.text(1) ?? "", text: row.text(2), attributedBody: row.blob(3),
                  date: row.int(4), isFromMe: row.int(5) != 0, handleId: row.int(6), associatedType: row.int(7),
                  associatedGuid: row.text(8), threadOriginatorGuid: row.text(9), destinationCallerId: row.text(10),
                  handle: row.text(11), handleService: row.text(12), chatRowid: row.int(13),
                  chatGuid: row.text(14) ?? "", chatIdentifier: row.text(15), chatService: row.text(16))
    }
}

extension RawRow {
    /// The sender's service: handle.service, or for an is_from_me row whose handle join
    /// is null, the chat's service_name. Admission and the `message` event both read it.
    var senderService: String? {
        handleService ?? (isFromMe ? chatService : nil)
    }
}

struct RawAttachment: Equatable {
    let index: Int
    let guid: String
    let filename: String?
    let mime: String?
    let bytes: Int64
}

/// UTC timestamps on the wire: ISO-8601 at whole seconds ("2026-10-03T12:00:00Z"),
/// with milliseconds only when the instant has a fraction ("…12:00:00.250Z").
enum Timestamp {
    private static let seconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let milliseconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func format(_ date: Date) -> String {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        let whole = millis.truncatingRemainder(dividingBy: 1000) == 0
        return (whole ? seconds : milliseconds).string(from: Date(timeIntervalSince1970: millis / 1000))
    }
}

/// A row with everything derived from it: the decoded text, the date, the reaction, the
/// direct/group shape and the attachments. Admission and the `message` event read this.
struct DecodedRow {
    static let appleEpochOffset: TimeInterval = 978_307_200
    static let futureAllowance: TimeInterval = 60
    static let reactionTypes: [ClosedRange<Int64>] = [2000...2006, 3000...3006]

    let raw: RawRow
    let text: String?
    let decodeError: String?
    let date: Date
    let dateClamped: Bool
    let reaction: Reaction?
    let isGroup: Bool
    let attachments: [RawAttachment]

    init(_ raw: RawRow, attachments: [RawAttachment], now: Date) {
        self.raw = raw
        self.attachments = attachments
        (text, decodeError) = Self.decodeText(raw)
        (date, dateClamped) = Self.decodeDate(raw.date, now: now)
        reaction = Self.decodeReaction(raw)
        isGroup = !(raw.chatGuid.contains(";-;") && !raw.chatGuid.contains(";+;"))
    }

    /// The counterpart of a direct chat, normalized; nil when it is not normalizable.
    var counterpart: String? {
        raw.chatIdentifier.flatMap { Handles.normalize($0).successValue }
    }

    var event: MessageEvent {
        let senderHandle = raw.isFromMe ? raw.destinationCallerId : raw.handle
        let senderService = raw.senderService ?? ""
        return MessageEvent(
            rowid: raw.rowid, guid: raw.guid,
            chat: ChatRef(rowid: raw.chatRowid, guid: raw.chatGuid, identifier: raw.chatIdentifier ?? "",
                          service: raw.chatService ?? "", group: isGroup),
            sender: SenderRef(handle: senderHandle.flatMap { Handles.normalize($0).successValue },
                              service: senderService, isMe: raw.isFromMe),
            date: Timestamp.format(date), text: text, decodeError: decodeError,
            replyToGuid: raw.threadOriginatorGuid,
            attachments: attachments.map {
                AttachmentRef(index: $0.index, guid: $0.guid,
                              name: $0.filename.map { ($0 as NSString).lastPathComponent }, mime: $0.mime,
                              bytes: $0.bytes)
            },
            reaction: reaction)
    }

    static func decodeText(_ raw: RawRow) -> (String?, String?) {
        if let text = raw.text, !text.isEmpty { return (text, nil) }
        guard let body = raw.attributedBody, !body.isEmpty else { return (raw.text, nil) }
        switch Typedstream.extractText(body) {
        case .success(let text): return (text, nil)
        case .failure(let error): return (nil, error.rawValue)
        }
    }

    /// Nanoseconds since 2001-01-01 UTC; magnitudes below 10^12 are seconds (older
    /// databases). Never later than now + 60 s: such a date is clamped and flagged.
    static func decodeDate(_ value: Int64, now: Date) -> (Date, Bool) {
        let seconds = value.magnitude < 1_000_000_000_000 ? Double(value) : Double(value) / 1_000_000_000
        let date = Date(timeIntervalSince1970: seconds + appleEpochOffset)
        if date.timeIntervalSince(now) > futureAllowance { return (now, true) }
        return (date, false)
    }

    static func decodeReaction(_ raw: RawRow) -> Reaction? {
        guard reactionTypes.contains(where: { $0.contains(raw.associatedType) }) else { return nil }
        return Reaction(type: Int(raw.associatedType), targetGuid: raw.associatedGuid.map(stripTargetPrefix))
    }

    /// `p:0/GUID` and `bp:GUID` both name GUID.
    static func stripTargetPrefix(_ value: String) -> String {
        if let slash = value.lastIndex(of: "/") { return String(value[value.index(after: slash)...]) }
        if value.hasPrefix("bp:") { return String(value.dropFirst(3)) }
        return value
    }
}
