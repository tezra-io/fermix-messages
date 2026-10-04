import Foundation

// The NDJSON wire of design §6, protocol v1. One JSON object per line:
//   request       {"id": n, "method": "...", "params": {...}}
//   response      {"id": n, "result": ...} | {"id": n, "error": {"kind", "message", "data"}}
//   notification  {"event": "...", "params": {...}}
// Keys are written sorted and slashes unescaped, so a response is byte-comparable with the
// goldens in Tests/Fixtures/protocol/ that the engine's codec shares. A wire change moves
// `Wire.protocolVersion` and the engine's pin together.

public enum Wire {
    public static let protocolVersion = 1

    /// A line that is not a JSON object with an integer `id` and a string `method` cannot
    /// be answered (there is no id to answer), so it ends `serve` with exit 76.
    public struct LineError: Error, Equatable {
        public let reason: String
    }

    public static func decodeRequest(_ line: Data) -> Result<Request, LineError> {
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: line)
            return .success(Request(id: envelope.id, method: envelope.method, raw: line))
        } catch {
            return .failure(LineError(reason: describe(error)))
        }
    }

    public static func encodeResult<T: Encodable>(id: Int64, _ result: T) -> Data {
        encode(ResultEnvelope(id: id, result: result))
    }

    public static func encodeError(id: Int64, _ error: HelperError) -> Data {
        encode(ErrorEnvelope(id: id, error: error))
    }

    public static func encodeNotification<T: Encodable>(_ event: Event, _ params: T) -> Data {
        encode(NotificationEnvelope(event: event.rawValue, params: params))
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            // Every wire type is a plain struct of strings, integers and arrays; an
            // encoding failure is a programming error, never a runtime condition.
            preconditionFailure("wire encoding failed: \(error)")
        }
    }

    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error) }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing \(path(context.codingPath + [key]))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: decoding)
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.isEmpty ? "line" : keys.map(\.stringValue).joined(separator: ".")
    }

    private struct Envelope: Decodable {
        let id: Int64
        let method: String
    }

    private struct ParamsEnvelope<T: Decodable>: Decodable {
        let params: T
    }

    private struct ResultEnvelope<T: Encodable>: Encodable {
        let id: Int64
        let result: T

        enum CodingKeys: String, CodingKey { case id, result }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        }
    }

    private struct ErrorEnvelope: Encodable {
        let id: Int64
        let error: HelperError
    }

    private struct NotificationEnvelope<T: Encodable>: Encodable {
        let event: String
        let params: T
    }

    static func decodeParams<T: Decodable>(_ type: T.Type, from raw: Data) -> Result<T, HelperError> {
        do {
            return .success(try JSONDecoder().decode(ParamsEnvelope<T>.self, from: raw).params)
        } catch let error as HelperError {
            return .failure(error)
        } catch {
            return .failure(HelperError(.protocolMismatch, "malformed params: \(describe(error))"))
        }
    }
}

public struct Request {
    public let id: Int64
    public let method: String
    let raw: Data

    /// Typed params; a missing or malformed `params` object is `protocol_mismatch`.
    func params<T: Decodable>(_ type: T.Type) -> Result<T, HelperError> {
        Wire.decodeParams(type, from: raw)
    }
}

public enum Method: String, CaseIterable {
    case initialize
    case probe
    case grant
    case policyGet = "policy.get"
    case policySet = "policy.set"
    case watchSubscribe = "watch.subscribe"
    case watchUnsubscribe = "watch.unsubscribe"
    case messagesAfter = "messages.after"
    case sendText = "send.text"
    case sendFile = "send.file"
    case attachmentFetch = "attachment.fetch"
    case shutdown
}

public enum Event: String {
    case message
    case watchOverflow = "watch.overflow"
    case dbState = "db.state"
    case sendReconciled = "send.reconciled"
    case policyState = "policy.state"
}

// MARK: - Errors

/// The closed error vocabulary of §6, exactly the engine's set.
public enum ErrorKind: String, Codable, CaseIterable {
    case notInitialized = "not_initialized"
    case protocolMismatch = "protocol_mismatch"
    case permissionDenied = "permission_denied"
    case dbMissing = "db_missing"
    case dbUnreadable = "db_unreadable"
    case dbSchemaUnexpected = "db_schema_unexpected"
    case policyAbsent = "policy_absent"
    case policyUnconfirmed = "policy_unconfirmed"
    case policyRefused = "policy_refused"
    case policyViolation = "policy_violation"
    // No longer produced: the posture is derived and nothing asks for own_account.
    case ownerNotSelf = "owner_not_self"
    case ownerIsThisMac = "owner_is_this_mac"
    case notSignedIn = "not_signed_in"
    case noUserSession = "no_user_session"
    case serviceNotImessage = "service_not_imessage"
    case chatNotFound = "chat_not_found"
    case automationRefused = "automation_refused"
    case sendTimeout = "send_timeout"
    case pathRefused = "path_refused"
    case attachmentNotAdmitted = "attachment_not_admitted"
    case attachmentTooLarge = "attachment_too_large"
    case busy
}

public struct HelperError: Error, Equatable, Encodable {
    public let kind: ErrorKind
    public let message: String
    public let data: [String: JSONValue]

    public init(_ kind: ErrorKind, _ message: String, data: [String: JSONValue] = [:]) {
        self.kind = kind
        self.message = message
        self.data = data
    }

    static func permissionDenied(_ service: Service, _ message: String) -> HelperError {
        HelperError(.permissionDenied, message, data: ["service": .string(service.rawValue)])
    }

    static func schemaUnexpected(missing: [String]) -> HelperError {
        let noun = missing.count == 1 ? "column" : "columns"
        return HelperError(.dbSchemaUnexpected, "chat.db lacks \(missing.count) expected \(noun)",
                           data: ["missing": .array(missing.map { .string($0) })])
    }

    static func policyViolation(handle: String, _ message: String) -> HelperError {
        HelperError(.policyViolation, message, data: ["handle": .string(handle)])
    }

    /// The owner handle is one of this Mac's own Messages addresses (§9): refused at
    /// `policy.set`, and for sends to the owner once the watcher has seen it.
    static let ownerIsThisMac = HelperError(
        .ownerIsThisMac, "Messages on this Mac is signed in as this address. Sign Messages in with a separate "
            + "Apple ID for Fermix, then confirm again.")

    static func tooLarge(bytes: Int64, cap: Int64) -> HelperError {
        HelperError(.attachmentTooLarge, "over \(cap / (1024 * 1024)) MB", data: ["bytes": .int(bytes)])
    }
}

/// A JSON value, for error `data` and anything else that is not a fixed model.
public enum JSONValue: Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .int(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Params

public enum Service: String, Codable {
    case automation
    case fullDiskAccess = "full_disk_access"
}

public enum Posture: String, Codable {
    case ownAccount = "own_account"
    case dedicatedAccount = "dedicated_account"
}

private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw HelperError(.protocolMismatch, "malformed params: \(message())") }
}

struct InitializeParams: Decodable {
    let protocolVersion: Int
    let client: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case client
    }
}

struct GrantParams: Decodable {
    let service: Service
}

/// No posture: the helper derives it from this Mac's own aliases (§9).
struct PolicySetParams: Decodable {
    let ownerHandle: String
    let handles: [String]

    enum CodingKeys: String, CodingKey {
        case ownerHandle = "owner_handle"
        case handles
    }
}

struct ReplayBounds: Decodable, Equatable {
    let maxRows: Int
    let maxAgeS: Int

    enum CodingKeys: String, CodingKey {
        case maxRows = "max_rows"
        case maxAgeS = "max_age_s"
    }

    init(maxRows: Int, maxAgeS: Int) {
        self.maxRows = maxRows
        self.maxAgeS = maxAgeS
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxRows = try container.decode(Int.self, forKey: .maxRows)
        maxAgeS = try container.decode(Int.self, forKey: .maxAgeS)
        try require((0...10_000).contains(maxRows), "replay.max_rows must be 0...10000")
        try require(maxAgeS >= 0, "replay.max_age_s must be >= 0")
    }
}

struct SubscribeParams: Decodable {
    static let bufferRange = 1...4096
    let sinceRowid: Int64?
    let replay: ReplayBounds?
    let bufferLimit: Int

    enum CodingKeys: String, CodingKey {
        case sinceRowid = "since_rowid"
        case replay
        case bufferLimit = "buffer_limit"
    }

    init(sinceRowid: Int64?, replay: ReplayBounds?, bufferLimit: Int) {
        self.sinceRowid = sinceRowid
        self.replay = replay
        self.bufferLimit = bufferLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sinceRowid = try container.decodeIfPresent(Int64.self, forKey: .sinceRowid)
        replay = try container.decodeIfPresent(ReplayBounds.self, forKey: .replay)
        bufferLimit = try container.decode(Int.self, forKey: .bufferLimit)
        try require(Self.bufferRange.contains(bufferLimit), "buffer_limit must be 1...4096")
        try require((sinceRowid ?? 0) >= 0, "since_rowid must be >= 0")
    }
}

struct MessagesAfterParams: Decodable {
    static let maxLimit = 256
    let sinceRowid: Int64
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case sinceRowid = "since_rowid"
        case limit
    }

    init(sinceRowid: Int64, limit: Int) {
        self.sinceRowid = sinceRowid
        self.limit = limit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sinceRowid = try container.decode(Int64.self, forKey: .sinceRowid)
        limit = try container.decode(Int.self, forKey: .limit)
        try require((1...Self.maxLimit).contains(limit), "limit must be 1...256")
        try require(sinceRowid >= 0, "since_rowid must be >= 0")
    }
}

struct SendTextParams: Decodable {
    let to: String
    let text: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case to, text
        case idempotencyKey = "idempotency_key"
    }

    init(to: String, text: String, idempotencyKey: String) {
        self.to = to
        self.text = text
        self.idempotencyKey = idempotencyKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        text = try container.decode(String.self, forKey: .text)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        try require(!text.isEmpty, "text must not be empty")
        try require(!idempotencyKey.isEmpty, "idempotency_key must not be empty")
    }
}

struct SendFileParams: Decodable {
    let to: String
    let path: String
    let mime: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case to, path, mime
        case idempotencyKey = "idempotency_key"
    }

    init(to: String, path: String, mime: String, idempotencyKey: String) {
        self.to = to
        self.path = path
        self.mime = mime
        self.idempotencyKey = idempotencyKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        path = try container.decode(String.self, forKey: .path)
        mime = try container.decode(String.self, forKey: .mime)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        try require(!path.isEmpty, "path must not be empty")
        try require(!idempotencyKey.isEmpty, "idempotency_key must not be empty")
    }
}

struct AttachmentFetchParams: Decodable, Equatable {
    let messageGuid: String
    let index: Int
    let convert: Bool

    enum CodingKeys: String, CodingKey {
        case messageGuid = "message_guid"
        case index, convert
    }

    init(messageGuid: String, index: Int, convert: Bool) {
        self.messageGuid = messageGuid
        self.index = index
        self.convert = convert
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageGuid = try container.decode(String.self, forKey: .messageGuid)
        index = try container.decode(Int.self, forKey: .index)
        convert = try container.decode(Bool.self, forKey: .convert)
        try require(!messageGuid.isEmpty, "message_guid must not be empty")
        try require(index >= 0, "index must be >= 0")
    }
}

// MARK: - Results

/// `{inode, birth_time}` of chat.db; `birth_time` is ISO-8601 UTC at whole seconds.
struct DBGeneration: Encodable, Equatable {
    let inode: UInt64
    let birthTime: String

    enum CodingKeys: String, CodingKey {
        case inode
        case birthTime = "birth_time"
    }
}

struct InitializeResult: Encodable {
    let protocolVersion: Int
    let helperVersion: String
    let macosVersion: String
    let bundleId: String?
    let dbGeneration: DBGeneration?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case helperVersion = "helper_version"
        case macosVersion = "macos_version"
        case bundleId = "bundle_id"
        case dbGeneration = "db_generation"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(helperVersion, forKey: .helperVersion)
        try container.encode(macosVersion, forKey: .macosVersion)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(dbGeneration, forKey: .dbGeneration)
    }
}

enum FullDiskAccess: String, Encodable { case granted, denied }

enum DBState: String, Encodable {
    case readable, missing, unreadable
    case schemaUnexpected = "schema_unexpected"
}

enum AutomationState: String, Encodable {
    case granted, denied, unknown
    case notDetermined = "not_determined"
}

/// `true | false | "unknown"` on the wire.
enum Tri: Encodable, Equatable {
    case yes, no, unknown

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .yes: try container.encode(true)
        case .no: try container.encode(false)
        case .unknown: try container.encode("unknown")
        }
    }
}

enum PolicyState: String, Encodable { case confirmed, unconfirmed, absent }

/// The probe (§6) plus `helper_version`, which the engine's one-shot parser requires.
struct ProbeResult: Encodable {
    let helperVersion: String
    let fullDiskAccess: FullDiskAccess
    let db: DBState
    let automation: AutomationState
    let messagesRunning: Bool
    let signedIn: Tri
    let userSession: Bool
    let policy: PolicyState
    let selfAliases: [String]?

    enum CodingKeys: String, CodingKey {
        case helperVersion = "helper_version"
        case fullDiskAccess = "full_disk_access"
        case db, automation
        case messagesRunning = "messages_running"
        case signedIn = "signed_in"
        case userSession = "user_session"
        case policy
        case selfAliases = "self_aliases"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(helperVersion, forKey: .helperVersion)
        try container.encode(fullDiskAccess, forKey: .fullDiskAccess)
        try container.encode(db, forKey: .db)
        try container.encode(automation, forKey: .automation)
        try container.encode(messagesRunning, forKey: .messagesRunning)
        try container.encode(signedIn, forKey: .signedIn)
        try container.encode(userSession, forKey: .userSession)
        try container.encode(policy, forKey: .policy)
        try container.encode(selfAliases, forKey: .selfAliases)
    }
}

struct PolicyView: Encodable {
    let posture: Posture
    let ownerHandle: String
    let handles: [String]
    let confirmedAt: String?

    enum CodingKeys: String, CodingKey {
        case posture
        case ownerHandle = "owner_handle"
        case handles
        case confirmedAt = "confirmed_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(posture, forKey: .posture)
        try container.encode(ownerHandle, forKey: .ownerHandle)
        try container.encode(handles, forKey: .handles)
        try container.encode(confirmedAt, forKey: .confirmedAt)
    }
}

struct PolicySetResult: Encodable, Equatable {
    let confirmedAt: String
    let posture: Posture

    enum CodingKeys: String, CodingKey {
        case confirmedAt = "confirmed_at"
        case posture
    }
}

struct SubscribeResult: Encodable, Equatable {
    let startedAtRowid: Int64
    let replaySkipped: Int

    enum CodingKeys: String, CodingKey {
        case startedAtRowid = "started_at_rowid"
        case replaySkipped = "replay_skipped"
    }
}

struct EmptyResult: Encodable {}

struct MessagesAfterResult: Encodable {
    let messages: [MessageEvent]
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }
}

enum Disposition: String, Codable { case recorded, uncertain, failed }

struct SendResult: Encodable, Equatable {
    let disposition: Disposition
    let guid: String?
    let rowid: Int64?
    let failureClass: ErrorKind?

    enum CodingKeys: String, CodingKey {
        case disposition, guid, rowid
        case failureClass = "class"
    }

    static let uncertain = SendResult(disposition: .uncertain, guid: nil, rowid: nil, failureClass: nil)

    static func failed(_ kind: ErrorKind) -> SendResult {
        SendResult(disposition: .failed, guid: nil, rowid: nil, failureClass: kind)
    }

    static func recorded(guid: String, rowid: Int64) -> SendResult {
        SendResult(disposition: .recorded, guid: guid, rowid: rowid, failureClass: nil)
    }
}

struct AttachmentFetchResult: Encodable, Equatable {
    let path: String
    let mime: String?
    let bytes: Int64

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(mime, forKey: .mime)
        try container.encode(bytes, forKey: .bytes)
    }

    enum CodingKeys: String, CodingKey { case path, mime, bytes }
}

// MARK: - Notifications

struct ChatRef: Encodable, Equatable {
    let rowid: Int64
    let guid: String
    let identifier: String
    let service: String
    let group: Bool
}

/// `service` is the sender's handle.service ("iMessage" | "SMS"), or the chat's
/// service_name for an is_me row whose handle join is null; the engine drops a row
/// without it.
struct SenderRef: Encodable, Equatable {
    let handle: String?
    let service: String
    let isMe: Bool

    enum CodingKeys: String, CodingKey {
        case handle, service
        case isMe = "is_me"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handle, forKey: .handle)
        try container.encode(service, forKey: .service)
        try container.encode(isMe, forKey: .isMe)
    }
}

struct AttachmentRef: Encodable, Equatable {
    let index: Int
    let guid: String
    let name: String?
    let mime: String?
    let bytes: Int64

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(guid, forKey: .guid)
        try container.encode(name, forKey: .name)
        try container.encode(mime, forKey: .mime)
        try container.encode(bytes, forKey: .bytes)
    }

    enum CodingKeys: String, CodingKey { case index, guid, name, mime, bytes }
}

struct Reaction: Encodable, Equatable {
    let type: Int
    let targetGuid: String?

    enum CodingKeys: String, CodingKey {
        case type
        case targetGuid = "target_guid"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(targetGuid, forKey: .targetGuid)
    }
}

struct MessageEvent: Encodable, Equatable {
    let rowid: Int64
    let guid: String
    let chat: ChatRef
    let sender: SenderRef
    let date: String
    let text: String?
    let decodeError: String?
    let replyToGuid: String?
    let attachments: [AttachmentRef]
    let reaction: Reaction?

    enum CodingKeys: String, CodingKey {
        case rowid, guid, chat, sender, date, text
        case decodeError = "decode_error"
        case replyToGuid = "reply_to_guid"
        case attachments, reaction
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rowid, forKey: .rowid)
        try container.encode(guid, forKey: .guid)
        try container.encode(chat, forKey: .chat)
        try container.encode(sender, forKey: .sender)
        try container.encode(date, forKey: .date)
        try container.encode(text, forKey: .text)
        try container.encode(decodeError, forKey: .decodeError)
        try container.encode(replyToGuid, forKey: .replyToGuid)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(reaction, forKey: .reaction)
    }
}

struct OverflowEvent: Encodable, Equatable {
    let dropped: Int
    let resumeAfterRowid: Int64

    enum CodingKeys: String, CodingKey {
        case dropped
        case resumeAfterRowid = "resume_after_rowid"
    }
}

enum Availability: String, Encodable { case available, unavailable }

/// `db_generation` is chat.db's generation when the event was emitted (null when it
/// cannot be stat'd), so the engine records the new generation instead of guessing.
struct DBStateEvent: Encodable, Equatable {
    let state: Availability
    let eventClass: String?
    let dbGeneration: DBGeneration?

    enum CodingKeys: String, CodingKey {
        case state
        case eventClass = "class"
        case dbGeneration = "db_generation"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(eventClass, forKey: .eventClass)
        try container.encode(dbGeneration, forKey: .dbGeneration)
    }
}

/// The confirmed policy no longer holds as confirmed. One state today: the watcher saw
/// the owner's own self chat under a dedicated policy. `owner` is redacted.
struct PolicyStateEvent: Encodable, Equatable {
    enum State: String, Encodable {
        case ownerIsThisMac = "owner_is_this_mac"
    }

    let state: State
    let owner: String
}

struct ReconciledEvent: Encodable, Equatable {
    let idempotencyKey: String
    let disposition: Disposition
    let guid: String?

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case disposition, guid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(disposition, forKey: .disposition)
        try container.encode(guid, forKey: .guid)
    }
}
