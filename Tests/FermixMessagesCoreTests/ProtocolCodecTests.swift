import Foundation
import Testing
@testable import FermixMessagesCore

/// Goldens for the NDJSON wire (design §6). `Tests/Fixtures/protocol/` mirrors the
/// engine's `apps/fermix_channels/test/fixtures/imessage/protocol/` file for file (one
/// `<method>.jsonl` with the request first and then each response shape, the
/// `notification.*.jsonl` files and `errors.jsonl`), plus the helper's additions:
/// `db_generation` on `db.state`, `helper_version` on the probe, and `send_timeout` on
/// an uncertain send. Lines are compared as JSON values (key order is free; booleans and
/// integers stay distinct).
@Suite struct ProtocolCodecTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/protocol")

    static func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: directory.appendingPathComponent(name + ".jsonl"), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    static func value(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func request(_ line: String) throws -> Request {
        switch Wire.decodeRequest(Data(line.utf8)) {
        case .success(let request): return request
        case .failure(let failure): throw failure
        }
    }

    /// Asserts that the helper's encoding equals the golden line as a JSON value.
    static func expectSame(_ produced: Data, _ golden: String, _ name: String) throws {
        let mine = try JSONDecoder().decode(JSONValue.self, from: produced)
        #expect(mine == (try value(golden)), "\(name)\n helper: \(String(decoding: produced, as: UTF8.self))")
    }

    static let chat = ChatRef(rowid: 17, guid: "any;-;+15551234567", identifier: "+15551234567", service: "iMessage",
                              group: false)
    static let sender = SenderRef(handle: "+15551234567", service: "iMessage", isMe: false)
    static let generation = DBGeneration(inode: 4_815_162_342, birthTime: "2026-09-01T08:00:00Z")

    @Test func everyFixtureFileIsCovered() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(".jsonl".count)) }
        let methods = Set(Method.allCases.map(\.rawValue))
        let notifications: Set<String> = ["notification.message", "notification.watch.overflow",
                                          "notification.db.state", "notification.send.reconciled",
                                          "notification.policy.state"]
        #expect(Set(names) == methods.union(notifications).union(["errors"]))
    }

    @Test func initialize() throws {
        let lines = try Self.lines("initialize")
        let params = try Self.request(lines[0]).params(InitializeParams.self).get()
        #expect(params.protocolVersion == 1)
        #expect(params.client == "fermix 0.12.1")
        let result = InitializeResult(protocolVersion: 1, helperVersion: "0.1.0", macosVersion: "27.0",
                                      bundleId: "io.tezra.fermix.messages", dbGeneration: Self.generation)
        try Self.expectSame(Wire.encodeResult(id: 1, result), lines[1], "initialize")
        let none = InitializeResult(protocolVersion: 1, helperVersion: "0.1.0", macosVersion: "27.0",
                                    bundleId: "io.tezra.fermix.messages", dbGeneration: nil)
        try Self.expectSame(Wire.encodeResult(id: 1, none), lines[2], "initialize without chat.db")
        let mismatch = HelperError(.protocolMismatch, "helper speaks protocol 2, client asked for 1",
                                   data: ["helper": .int(2), "client": .int(1)])
        try Self.expectSame(Wire.encodeError(id: 1, mismatch), lines[3], "initialize mismatch")
    }

    @Test func probeAndGrant() throws {
        let probe = try Self.lines("probe")
        #expect(try Self.request(probe[0]).method == "probe")
        let green = ProbeResult(helperVersion: "0.1.0", fullDiskAccess: .granted, db: .readable, automation: .granted, messagesRunning: true,
                                signedIn: .yes, userSession: true, policy: .confirmed, selfAliases: ["+15550001111"])
        try Self.expectSame(Wire.encodeResult(id: 2, green), probe[1], "probe green")
        let zero = ProbeResult(helperVersion: "0.1.0", fullDiskAccess: .denied, db: .unreadable, automation: .unknown, messagesRunning: false,
                               signedIn: .unknown, userSession: true, policy: .absent, selfAliases: nil)
        try Self.expectSame(Wire.encodeResult(id: 2, zero), probe[2], "probe zero")

        let grant = try Self.lines("grant")
        #expect(try Self.request(grant[0]).params(GrantParams.self).get().service == .automation)
        let after = ProbeResult(helperVersion: "0.1.0", fullDiskAccess: .granted, db: .readable, automation: .granted, messagesRunning: true,
                                signedIn: .yes, userSession: true, policy: .unconfirmed, selfAliases: ["+15550001111"])
        try Self.expectSame(Wire.encodeResult(id: 3, after), grant[1], "grant")
        try Self.expectSame(Wire.encodeError(id: 3, HelperError(.noUserSession, "no console session to show the prompt in")),
                            grant[2], "grant without a session")
    }

    @Test func policy() throws {
        let get = try Self.lines("policy.get")
        #expect(try Self.request(get[0]).method == "policy.get")
        let view = PolicyView(posture: .dedicatedAccount, ownerHandle: "+15551234567",
                              handles: ["+15551234567", "guest@example.com"], confirmedAt: "2026-10-01T09:30:00Z")
        try Self.expectSame(Wire.encodeResult(id: 4, view), get[1], "policy.get")
        let absent = Wire.encodeResult(id: 4, PolicyView?.none)
        #expect(String(decoding: absent, as: UTF8.self) == #"{"id":4,"result":null}"#)

        let set = try Self.lines("policy.set")
        let params = try Self.request(set[0]).params(PolicySetParams.self).get()
        #expect(params.ownerHandle == "+15551234567")
        #expect(params.handles == ["+15551234567", "guest@example.com"])
        let confirmed = PolicySetResult(confirmedAt: "2026-10-01T09:30:00Z", posture: .dedicatedAccount)
        try Self.expectSame(Wire.encodeResult(id: 5, confirmed), set[1], "policy.set")
        try Self.expectSame(Wire.encodeError(id: 5, HelperError(.policyRefused, "the owner cancelled the confirmation")),
                            set[2], "policy.set refused")
        try Self.expectSame(Wire.encodeError(id: 5, .ownerIsThisMac), set[3], "policy.set owner_is_this_mac")
    }

    @Test func watch() throws {
        let subscribe = try Self.lines("watch.subscribe")
        let params = try Self.request(subscribe[0]).params(SubscribeParams.self).get()
        #expect(params.sinceRowid == 4000)
        #expect(params.replay == ReplayBounds(maxRows: 50, maxAgeS: 600))
        #expect(params.bufferLimit == 256)
        try Self.expectSame(Wire.encodeResult(id: 6, SubscribeResult(startedAtRowid: 4020, replaySkipped: 3)),
                            subscribe[1], "watch.subscribe")
        try Self.expectSame(Wire.encodeError(id: 6, HelperError(.policyUnconfirmed, "the recipient policy is not confirmed")),
                            subscribe[2], "watch.subscribe unconfirmed")
        let unsubscribe = try Self.lines("watch.unsubscribe")
        #expect(try Self.request(unsubscribe[0]).method == "watch.unsubscribe")
        try Self.expectSame(Wire.encodeResult(id: 7, EmptyResult()), unsubscribe[1], "watch.unsubscribe")
        let shutdown = try Self.lines("shutdown")
        try Self.expectSame(Wire.encodeResult(id: 12, EmptyResult()), shutdown[1], "shutdown")
    }

    static let hello = MessageEvent(rowid: 4021, guid: "F1C2E3A4-0001-4B5C-9D6E-7F8091A2B3C4", chat: chat, sender: sender,
                                    date: "2026-10-03T12:00:00Z", text: "hello fermix", decodeError: nil,
                                    replyToGuid: nil, attachments: [], reaction: nil)

    @Test func messagesAfter() throws {
        let lines = try Self.lines("messages.after")
        let params = try Self.request(lines[0]).params(MessagesAfterParams.self).get()
        #expect(params.sinceRowid == 4020)
        #expect(params.limit == 64)
        try Self.expectSame(Wire.encodeResult(id: 8, MessagesAfterResult(messages: [Self.hello], hasMore: false)),
                            lines[1], "messages.after")
    }

    @Test func sends() throws {
        let text = try Self.lines("send.text")
        let params = try Self.request(text[0]).params(SendTextParams.self).get()
        #expect(params.to == "+15551234567")
        #expect(params.text == "Here is the answer.")
        #expect(params.idempotencyKey == "turn:t-42:1:text:0")
        try Self.expectSame(Wire.encodeResult(id: 9, SendResult.recorded(guid: "A9B8C7D6-0002-4E5F-8A9B-0C1D2E3F4A5B",
                                                                          rowid: 4023)), text[1], "recorded")
        try Self.expectSame(Wire.encodeResult(id: 9, SendResult.uncertain), text[2], "uncertain")
        try Self.expectSame(Wire.encodeResult(id: 9, SendResult(disposition: .uncertain, guid: nil, rowid: nil,
                                                                failureClass: .sendTimeout)), text[3], "uncertain timeout")
        try Self.expectSame(Wire.encodeResult(id: 9, SendResult.failed(.chatNotFound)), text[4], "failed")
        try Self.expectSame(Wire.encodeError(id: 9, .policyViolation(handle: "+15559999999",
                                                                       "recipient is outside the confirmed policy")),
                            text[5], "policy_violation")

        let file = try Self.lines("send.file")
        let fileParams = try Self.request(file[0]).params(SendFileParams.self).get()
        #expect(fileParams.path == "/Users/owner/.fermix/imessage/outbox/6f1c0d2e-3b4a-4c5d-8e9f-0a1b2c3d4e5f/chart.png")
        #expect(fileParams.mime == "image/png")
        try Self.expectSame(Wire.encodeResult(id: 10, SendResult.recorded(guid: "B1C2D3E4-0003-4F5A-9B8C-7D6E5F4A3B2C",
                                                                           rowid: 4024)), file[1], "send.file")
        try Self.expectSame(Wire.encodeError(id: 10, HelperError(.pathRefused, "path is outside the outbox")), file[2],
                            "send.file refused")
    }

    @Test func attachmentFetch() throws {
        let lines = try Self.lines("attachment.fetch")
        let params = try Self.request(lines[0]).params(AttachmentFetchParams.self).get()
        #expect(params == AttachmentFetchParams(messageGuid: "F1C2E3A4-0002-4B5C-9D6E-7F8091A2B3C4", index: 0,
                                                convert: true))
        let result = AttachmentFetchResult(
            path: "/Users/owner/.fermix/imessage/inbox/F1C2E3A4-0002-4B5C-9D6E-7F8091A2B3C4/0-Audio_Message.m4a",
            mime: "audio/mp4", bytes: 51234)
        try Self.expectSame(Wire.encodeResult(id: 11, result), lines[1], "attachment.fetch")
        try Self.expectSame(Wire.encodeError(id: 11, HelperError(.attachmentNotAdmitted,
                                                                  "no admitted message carries that attachment")),
                            lines[2], "attachment.fetch refused")
    }

    @Test func everyErrorKindHasItsGoldenShape() throws {
        let lines = try Self.lines("errors")
        var kinds = Set<String>()
        for line in lines {
            guard case .object(let envelope) = try Self.value(line), case .object(let body)? = envelope["error"],
                  case .string(let kind)? = body["kind"], case .string(let message)? = body["message"],
                  case .object(let data)? = body["data"], let errorKind = ErrorKind(rawValue: kind) else {
                Issue.record("not an error line: \(line)")
                continue
            }
            kinds.insert(kind)
            try Self.expectSame(Wire.encodeError(id: 20, HelperError(errorKind, message, data: data)), line, kind)
        }
        #expect(kinds == Set(ErrorKind.allCases.map(\.rawValue)), "errors.jsonl names every kind once")
        try Self.expectSame(Wire.encodeError(id: 20, .tooLarge(bytes: 104_857_601, cap: 100 * 1024 * 1024)),
                            lines.first { $0.contains("attachment_too_large") }!, "attachment_too_large")
        try Self.expectSame(Wire.encodeError(id: 20, .schemaUnexpected(missing: ["message.attributedBody"])),
                            #"{"id":20,"error":{"kind":"db_schema_unexpected","message":"chat.db lacks 1 expected column","data":{"missing":["message.attributedBody"]}}}"#,
                            "schema")
    }

    @Test func notifications() throws {
        let messages = try Self.lines("notification.message")
        let attachment = AttachmentRef(index: 0, guid: "at_0_F1C2E3A4", name: "Audio Message.caf", mime: "audio/x-caf",
                                       bytes: 48213)
        let voice = MessageEvent(rowid: 4022, guid: "F1C2E3A4-0002-4B5C-9D6E-7F8091A2B3C4", chat: Self.chat,
                                 sender: Self.sender, date: "2026-10-03T12:00:05Z", text: nil,
                                 decodeError: Typedstream.DecodeError.truncated.rawValue,
                                 replyToGuid: "F1C2E3A4-0001-4B5C-9D6E-7F8091A2B3C4", attachments: [attachment],
                                 reaction: nil)
        let like = MessageEvent(rowid: 4023, guid: "F1C2E3A4-0003-4B5C-9D6E-7F8091A2B3C4", chat: Self.chat,
                                sender: Self.sender, date: "2026-10-03T12:00:09Z", text: nil, decodeError: nil,
                                replyToGuid: nil, attachments: [],
                                reaction: Reaction(type: 2000, targetGuid: "A9B8C7D6-0002-4E5F-8A9B-0C1D2E3F4A5B"))
        try Self.expectSame(Wire.encodeNotification(.message, Self.hello), messages[0], "message")
        try Self.expectSame(Wire.encodeNotification(.message, voice), messages[1], "message with attachment")
        try Self.expectSame(Wire.encodeNotification(.message, like), messages[2], "tapback")

        let overflow = try Self.lines("notification.watch.overflow")
        try Self.expectSame(Wire.encodeNotification(.watchOverflow, OverflowEvent(dropped: 44, resumeAfterRowid: 4300)),
                            overflow[0], "watch.overflow")

        let states = try Self.lines("notification.db.state")
        try Self.expectSame(Wire.encodeNotification(.dbState, DBStateEvent(state: .unavailable,
                                                                           eventClass: "generation_changed",
                                                                           dbGeneration: Self.generation)),
                            states[0], "db.state unavailable")
        try Self.expectSame(Wire.encodeNotification(.dbState, DBStateEvent(state: .available, eventClass: nil,
                                                                           dbGeneration: Self.generation)),
                            states[1], "db.state available")
        try Self.expectSame(Wire.encodeNotification(.dbState, DBStateEvent(state: .unavailable,
                                                                           eventClass: "permission_denied",
                                                                           dbGeneration: nil)),
                            states[2], "db.state without a file")

        let reconciled = try Self.lines("notification.send.reconciled")
        try Self.expectSame(Wire.encodeNotification(.sendReconciled, ReconciledEvent(
            idempotencyKey: "turn:t-42:1:text:0", disposition: .recorded, guid: "A9B8C7D6-0002-4E5F-8A9B-0C1D2E3F4A5B")),
            reconciled[0], "send.reconciled")
        try Self.expectSame(Wire.encodeNotification(.sendReconciled, ReconciledEvent(
            idempotencyKey: "proactive:temporal:r-7:main:text:0", disposition: .uncertain, guid: nil)),
            reconciled[1], "send.reconciled uncertain")

        let policyState = try Self.lines("notification.policy.state")
        try Self.expectSame(Wire.encodeNotification(.policyState, PolicyStateEvent(
            state: .ownerIsThisMac, owner: Handles.redact("+15551234567"))), policyState[0], "policy.state")
    }

    @Test func malformedLinesAreProtocolErrors() {
        for line in ["not json", "[1,2]", "{\"method\":\"probe\"}", "{\"id\":\"1\",\"method\":\"probe\"}",
                     "{\"id\":1.5,\"method\":\"probe\"}", "{\"id\":1}", "{\"id\":1,\"method\":7}", ""] {
            if case .success = Wire.decodeRequest(Data(line.utf8)) {
                Issue.record("accepted \(line)")
            }
        }
    }

    @Test func malformedParamsAreProtocolMismatch() throws {
        let cases: [(String, (Request) -> HelperError?)] = [
            (#"{"id":1,"method":"messages.after","params":{"since_rowid":"x","limit":5}}"#,
             { $0.params(MessagesAfterParams.self).failureValue }),
            (#"{"id":1,"method":"messages.after","params":{"since_rowid":1,"limit":257}}"#,
             { $0.params(MessagesAfterParams.self).failureValue }),
            (#"{"id":1,"method":"messages.after","params":{"since_rowid":1,"limit":0}}"#,
             { $0.params(MessagesAfterParams.self).failureValue }),
            (#"{"id":1,"method":"messages.after"}"#, { $0.params(MessagesAfterParams.self).failureValue }),
            (#"{"id":1,"method":"watch.subscribe","params":{"since_rowid":null,"replay":null,"buffer_limit":0}}"#,
             { $0.params(SubscribeParams.self).failureValue }),
            (#"{"id":1,"method":"grant","params":{"service":"contacts"}}"#, { $0.params(GrantParams.self).failureValue }),
            (#"{"id":1,"method":"policy.set","params":{"handles":["+15551234567"]}}"#,
             { $0.params(PolicySetParams.self).failureValue }),
            (#"{"id":1,"method":"attachment.fetch","params":{"message_guid":"g","index":-1,"convert":false}}"#,
             { $0.params(AttachmentFetchParams.self).failureValue }),
            (#"{"id":1,"method":"send.text","params":{"to":"+15551234567","text":"","idempotency_key":"k"}}"#,
             { $0.params(SendTextParams.self).failureValue }),
        ]
        for (line, decode) in cases {
            #expect(decode(try Self.request(line))?.kind == .protocolMismatch, "\(line)")
        }
    }

    @Test func theErrorVocabularyIsClosed() {
        #expect(ErrorKind.allCases.map(\.rawValue).sorted() == [
            "attachment_not_admitted", "attachment_too_large", "automation_refused", "busy",
            "chat_not_found", "db_missing", "db_schema_unexpected", "db_unreadable",
            "no_user_session", "not_initialized", "not_signed_in", "owner_is_this_mac", "owner_not_self", "path_refused",
            "permission_denied", "policy_absent", "policy_refused", "policy_unconfirmed",
            "policy_violation", "protocol_mismatch", "send_timeout", "service_not_imessage",
        ])
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
